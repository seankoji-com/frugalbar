import Foundation

/// Ingests CLI activity from OpenAI Codex (`$CODEX_HOME/sessions/`, default `~/.codex/sessions/`).
///
/// Shapes and what they mean (verified against local rollouts):
///
/// - `session_meta` carries `payload.session_id`, `payload.cwd`, and the
///   published `payload.model_provider` / `payload.creator_account_id`.
/// - A model change is a **top-level** `type: "turn_context"` event whose
///   `payload.model` applies from that point in the file onward. It is not an
///   `event_msg`, and `payload.type` is absent.
/// - `token_usage_record` carries `payload.usage` for one request, at the
///   top-level `timestamp`, plus `payload.thread_token_usage` cumulative for
///   the thread. `usage.input_tokens` already includes
///   `usage.cached_input_tokens`; `reasoning_output_tokens` is inside
///   `output_tokens`, and `total_tokens` is `input + output`.
/// - Older rollouts only have `event_msg` / `payload.type == "token_count"`
///   with a cumulative `info.total_token_usage` and (in newer files) a
///   per-turn `info.last_token_usage`. With no request rows to read, that
///   cumulative total is retained as one honestly session-level record.
///
/// Request rows are keyed by `response_id`, at the timestamp the source
/// recorded, so a resumed session or a fork that copies history cannot move
/// yesterday's usage into today or count the same request twice.
public struct CodexAdapter: ActivityAdapter, Sendable {
    public let sourceIdentifier: String = "codex"
    public let baseURL: URL?

    public init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
        } else if TestHost.isActive {
            self.baseURL = nil
        } else {
            self.baseURL = Self.defaultSessionsDirectory(
                environment: ProcessInfo.processInfo.environment,
                home: FileManager.default.homeDirectoryForCurrentUser,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) }
            )
        }
    }

    /// `$CODEX_HOME/sessions` when that directory exists, else
    /// `~/.codex/sessions` (see `CLIConfigLocations.codexRoot`).
    static func defaultSessionsDirectory(
        environment: [String: String],
        home: URL,
        fileExists: (URL) -> Bool
    ) -> URL {
        CLIConfigLocations.codexRoot(
            containing: "sessions", environment: environment, home: home, fileExists: fileExists
        ).appendingPathComponent("sessions", isDirectory: true)
    }

    private struct Usage {
        var input: Int?
        var output: Int?
        var cacheRead: Int?
        var cacheWrite: Int?
        var reasoning: Int?
        var total: Int?
    }

    public func collectActivities(watermarks: [String: ActivityWatermark]) async throws -> ActivityIngestResult {
        guard let baseURL, FileManager.default.fileExists(atPath: baseURL.path) else {
            return .empty
        }

        var records: [ActivityRecord] = []
        var updates: [ActivityWatermark] = []
        var skipped = 0
        var scanned = 0
        var malformed = 0
        var inconsistent = 0
        var incomplete = 0
        var inputDiagnostics: [ActivityInputDiagnostics] = []
        var consideredInputs: [String] = []
        /// One response observed in two files (a fork or a copied history) is
        /// one request. The first occurrence wins; a conflicting repeat is a
        /// diagnostic, not a second row.
        var observedRequests: [String: ActivityRecord] = [:]
        /// `(session, second, total)` of every request row already emitted by
        /// a `token_usage_record`. An `event_msg` `last_token_usage` for the
        /// same request is the same observation in the older shape.
        var recordedRequestKeys = Set<String>()

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoStandard = ISO8601DateFormatter()
        isoStandard.formatOptions = [.withInternetDateTime]

        func parseDate(_ str: String) -> Date? {
            isoWithFraction.date(from: str) ?? isoStandard.date(from: str)
        }

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "jsonl" else { continue }

            let resourceValues = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            )
            guard resourceValues?.isRegularFile == true else { continue }

            let size = Int64(resourceValues?.fileSize ?? 0)
            let mtime = Int64((resourceValues?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
            let path = fileURL.path
            consideredInputs.append(path)

            if let prior = watermarks[path], prior.isUnchanged(fileSize: size, modifiedAt: mtime) {
                continue
            }

            guard let data = try? Data(contentsOf: fileURL),
                  let content = String(data: data, encoding: .utf8) else {
                // Unreadable, or not text. No watermark is stored, so it is
                // tried again; the pass is reported as incomplete meanwhile.
                skipped += 1
                inputDiagnostics.append(ActivityInputDiagnostics(
                    filePath: path, recordsObserved: 0, readFailure: true))
                continue
            }

            scanned += 1
            let malformedBefore = malformed
            let inconsistentBefore = inconsistent
            let incompleteBefore = incomplete
            let recordsBefore = records.count

            var sessionId: String?
            var projectPath: String?
            var gitBranch: String?
            var model: String?
            var billingProvider: String?
            var accountId: String?
            var sessionStartedAt: Date?

            /// The latest cumulative counter seen, per thread. Compaction and a
            /// counter restart reset the baseline; no usage is fabricated from
            /// the difference between two counter readings.
            var cumulativeByThread: [String: Int] = [:]
            var lastLegacyUsage: Usage?
            var lastLegacyObservedAt: Date?
            var fileRequests: [ActivityRecord] = []
            /// Every request figure stated in this file, keyed by the same
            /// identity used across the two shapes. A fork's copy states the
            /// same requests as its parent; it still accounts for its own
            /// cumulative total.
            var fileRequestTotals: [String: Int] = [:]
            /// Requests reconstructed from `event_msg` `last_token_usage`.
            var lastUsageRequests: [ActivityRecord] = []

            for (lineIndex, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard let lineData = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    malformed += 1
                    continue
                }

                let lineType = json["type"] as? String
                let lineTimestamp = (json["timestamp"] as? String).flatMap(parseDate)

                if lineType == "session_meta", let payload = json["payload"] as? [String: Any] {
                    if let sid = payload["session_id"] as? String ?? payload["id"] as? String {
                        sessionId = sid
                    }
                    if let cwd = payload["cwd"] as? String {
                        projectPath = cwd
                    }
                    if let branch = payload["git_branch"] as? String {
                        gitBranch = branch
                    }
                    if let m = payload["model"] as? String {
                        model = m
                    }
                    if let provider = payload["model_provider"] as? String {
                        billingProvider = provider
                    }
                    if let account = payload["creator_account_id"] as? String {
                        accountId = account
                    }
                    if let ts = (payload["timestamp"] as? String).flatMap(parseDate) ?? lineTimestamp {
                        sessionStartedAt = ts
                    }
                } else if lineType == "turn_context", let payload = json["payload"] as? [String: Any] {
                    // The actual shape: a top-level turn_context, not an
                    // event_msg. Its model applies from this record onward.
                    if let m = payload["model"] as? String {
                        model = m
                    }
                    if let cwd = payload["cwd"] as? String {
                        projectPath = cwd
                    }
                } else if lineType == "token_usage_record", let payload = json["payload"] as? [String: Any] {
                    guard let usageObject = payload["usage"] as? [String: Any] else {
                        malformed += 1
                        continue
                    }
                    let parsed = parseUsage(usageObject, malformed: &malformed)
                    let observed = lineTimestamp ?? sessionStartedAt
                    guard let observed else {
                        // No recorded time means we cannot place this usage at
                        // its source time; keeping it would move it to now.
                        malformed += 1
                        continue
                    }
                    let effectiveSession = (payload["session_id"] as? String) ?? sessionId
                        ?? fileURL.deletingPathExtension().lastPathComponent
                    let recordId = requestRecordId(
                        payload: payload, lineIndex: lineIndex, observed: observed, usage: parsed)
                    let record = ActivityRecord(
                        source: sourceIdentifier,
                        recordId: recordId,
                        sessionId: effectiveSession,
                        projectPath: projectPath,
                        gitBranch: gitBranch,
                        model: model,
                        observedAt: observed,
                        inputTokens: parsed.input,
                        outputTokens: parsed.output,
                        cacheReadTokens: parsed.cacheRead,
                        cacheWriteTokens: parsed.cacheWrite,
                        reasoningTokens: parsed.reasoning,
                        totalTokens: parsed.total,
                        totalKind: parsed.total == nil ? nil : .published,
                        semantics: .cacheIncludedInInput,
                        granularity: .request,
                        billingProvider: billingProvider,
                        accountId: accountId,
                        workspaceId: nil
                    )

                    if let total = parsed.total {
                        fileRequestTotals[requestKey(
                            session: effectiveSession, observed: observed, total: total)] = total
                    }
                    if let prior = observedRequests[recordId] {
                        if prior.inputTokens != record.inputTokens
                            || prior.outputTokens != record.outputTokens
                            || prior.cacheReadTokens != record.cacheReadTokens
                            || prior.cacheWriteTokens != record.cacheWriteTokens
                            || prior.totalTokens != record.totalTokens {
                            inconsistent += 1
                        }
                    } else {
                        observedRequests[recordId] = record
                        fileRequests.append(record)
                        recordedRequestKeys.insert(requestKey(
                            session: record.sessionId, observed: record.observedAt, total: record.totalTokens))
                    }

                    // Reconcile the request's own published total against the
                    // thread's cumulative counter. A counter below its last
                    // value is a restart/compaction: reset the baseline and
                    // record nothing from the gap. No `nil` is invented as 0.
                    let threadId = (payload["thread_id"] as? String) ?? effectiveSession
                    if let cumulative = (payload["thread_token_usage"] as? [String: Any])
                        .flatMap({ TokenCountParsing.nonNegative($0["total_tokens"]) }) {
                        if let previous = cumulativeByThread[threadId], cumulative < previous {
                            cumulativeByThread[threadId] = cumulative
                        } else {
                            if let previous = cumulativeByThread[threadId],
                               let total = parsed.total,
                               cumulative - previous != total {
                                inconsistent += 1
                            }
                            cumulativeByThread[threadId] = cumulative
                        }
                    }
                } else if lineType == "event_msg", let payload = json["payload"] as? [String: Any] {
                    guard let pType = payload["type"] as? String else { continue }
                    if pType == "token_count" {
                        guard let info = payload["info"] as? [String: Any] else {
                            malformed += 1
                            continue
                        }
                        var cumulativeTotal: Int?
                        if let totalUsage = info["total_token_usage"] as? [String: Any] {
                            let parsed = parseUsage(totalUsage, malformed: &malformed)
                            lastLegacyUsage = parsed
                            lastLegacyObservedAt = lineTimestamp ?? lastLegacyObservedAt ?? sessionStartedAt
                            cumulativeTotal = parsed.total
                        }
                        // Newer rollouts publish per-request usage beside the
                        // cumulative counter. That is the same observation the
                        // ledger records; without reading it, earlier days
                        // were folded into one session total at the last turn.
                        if let lastUsage = info["last_token_usage"] as? [String: Any] {
                            let parsed = parseUsage(lastUsage, malformed: &malformed)
                            let effectiveSession = sessionId
                                ?? fileURL.deletingPathExtension().lastPathComponent
                            let observed = lineTimestamp ?? sessionStartedAt
                            guard let observed else {
                                // No recorded time means its day is unknown;
                                // placing it now would move yesterday's usage.
                                malformed += 1
                                continue
                            }
                            let key = requestKey(
                                session: effectiveSession, observed: observed, total: parsed.total)
                            if let total = parsed.total { fileRequestTotals[key] = total }
                            // The same request stated as a token_usage_record
                            // is already in the ledger.
                            if recordedRequestKeys.contains(key) { continue }

                            let recordId = lastUsageRecordId(
                                session: effectiveSession, observed: observed,
                                cumulative: cumulativeTotal, last: parsed)
                            let record = ActivityRecord(
                                source: sourceIdentifier,
                                recordId: recordId,
                                sessionId: effectiveSession,
                                projectPath: projectPath,
                                gitBranch: gitBranch,
                                model: model,
                                observedAt: observed,
                                inputTokens: parsed.input,
                                outputTokens: parsed.output,
                                cacheReadTokens: parsed.cacheRead,
                                cacheWriteTokens: parsed.cacheWrite,
                                reasoningTokens: parsed.reasoning,
                                totalTokens: parsed.total,
                                totalKind: parsed.total == nil ? nil : .published,
                                semantics: .cacheIncludedInInput,
                                granularity: .request,
                                billingProvider: billingProvider,
                                accountId: accountId,
                                workspaceId: nil
                            )

                            if let prior = observedRequests[recordId] {
                                if prior.totalTokens != record.totalTokens
                                    || prior.inputTokens != record.inputTokens
                                    || prior.outputTokens != record.outputTokens {
                                    inconsistent += 1
                                }
                            } else {
                                observedRequests[recordId] = record
                                lastUsageRequests.append(record)
                                recordedRequestKeys.insert(key)
                            }

                            // A counter below its last value is a restart or
                            // compaction. A counter that disagrees with the
                            // per-request figure is a diagnostic, never a
                            // fabricated difference.
                            if let cumulative = cumulativeTotal {
                                if let previous = cumulativeByThread[effectiveSession],
                                   cumulative < previous {
                                    cumulativeByThread[effectiveSession] = cumulative
                                } else {
                                    if let previous = cumulativeByThread[effectiveSession],
                                       let total = parsed.total,
                                       cumulative - previous != total {
                                        inconsistent += 1
                                    }
                                    cumulativeByThread[effectiveSession] = cumulative
                                }
                            }
                        }
                    }
                } else if lineType == "compacted" {
                    // Compaction starts a new counter segment. The records
                    // after it are observations, never differences from the
                    // pre-compaction total.
                    cumulativeByThread.removeAll()
                }
            }

            fileRequests += lastUsageRequests
            if !fileRequests.isEmpty {
                records += fileRequests
                incomplete += fileRequests.filter { $0.totalKind == .partial || $0.totalKind == .unknown }.count
            }

            // A cumulative-only region is retained as one honestly
            // session-level record, but only when it states more than the
            // request rows observed here. A fully reconstructed file adds no
            // aggregate; a partial one keeps the published session total so
            // the missing tokens are not silently dropped. The read surface
            // (activity_unified) suppresses whichever side is covered, so the
            // aggregate is never added to its own request rows.
            if let legacy = lastLegacyUsage {
                let observedRequestTotal = summed(Array(fileRequestTotals.values))
                let residual = legacy.total.map { total in
                    observedRequestTotal.map { total > $0 } ?? true
                } ?? (fileRequests.isEmpty)
                if residual {
                    let effectiveSessionId = sessionId ?? fileURL.deletingPathExtension().lastPathComponent
                    let observed = lastLegacyObservedAt ?? sessionStartedAt
                    if let observed {
                        let record = ActivityRecord(
                            source: sourceIdentifier,
                            recordId: "codex_\(effectiveSessionId)",
                            sessionId: effectiveSessionId,
                            projectPath: projectPath,
                            gitBranch: gitBranch,
                            model: model,
                            observedAt: observed,
                            inputTokens: legacy.input,
                            outputTokens: legacy.output,
                            cacheReadTokens: legacy.cacheRead,
                            cacheWriteTokens: legacy.cacheWrite,
                            reasoningTokens: legacy.reasoning,
                            totalTokens: legacy.total,
                            totalKind: legacy.total == nil ? nil : .published,
                            semantics: .cacheIncludedInInput,
                            granularity: .session,
                            billingProvider: billingProvider,
                            accountId: accountId,
                            workspaceId: nil
                        )
                        if observedRequests[record.recordId] == nil {
                            // One session aggregate, at the latest cumulative
                            // reading: a resumed or forked file states the
                            // same session total, not a second one.
                            if let index = records.firstIndex(where: {
                                $0.recordId == record.recordId
                            }) {
                                if records[index].observedAt <= record.observedAt {
                                    records[index] = record
                                }
                            } else {
                                records.append(record)
                            }
                        }
                        if record.totalKind == .partial || record.totalKind == .unknown {
                            incomplete += 1
                        }
                    }
                }
            }

            updates.append(ActivityWatermark(
                filePath: path,
                fileSize: size,
                modifiedAt: mtime,
                cursor: size
            ))
            inputDiagnostics.append(ActivityInputDiagnostics(
                filePath: path,
                malformedRecords: malformed - malformedBefore,
                inconsistentRecords: inconsistent - inconsistentBefore,
                incompleteRecords: incomplete - incompleteBefore,
                recordsObserved: records.count - recordsBefore))
        }

        return ActivityIngestResult(
            records: records,
            watermarks: updates,
            diagnostics: ActivityPassDiagnostics(
                scannedInputs: scanned,
                skippedInputs: skipped,
                malformedRecords: malformed,
                inconsistentRecords: inconsistent,
                incompleteRecords: incomplete,
                recordsObserved: records.count
            ),
            inputDiagnostics: inputDiagnostics,
            inputsConsidered: consideredInputs
        )
    }

    // MARK: - Parsing helpers

    /// Parse a Codex usage dictionary without inventing figures. A field that
    /// is present but not a non-negative integer is malformed: it does not
    /// become a measured zero.
    private func parseUsage(_ object: [String: Any], malformed: inout Int) -> Usage {
        func read(_ key: String) -> Int? {
            guard let raw = object[key], !(raw is NSNull) else { return nil }
            if let value = TokenCountParsing.nonNegative(raw) { return value }
            malformed += 1
            return nil
        }
        return Usage(
            input: read("input_tokens"),
            output: read("output_tokens"),
            cacheRead: read("cached_input_tokens"),
            cacheWrite: read("cache_write_input_tokens"),
            reasoning: read("reasoning_output_tokens"),
            total: read("total_tokens")
        )
    }

    /// Stable identity for a request stated only as `event_msg` usage. The
    /// cumulative counter disambiguates two requests in the same millisecond;
    /// a fork's copy states the same figures under the same id.
    private func lastUsageRecordId(
        session: String,
        observed: Date,
        cumulative: Int?,
        last: Usage
    ) -> String {
        let millis = Int64((observed.timeIntervalSince1970 * 1000).rounded())
        let counter = cumulative.map(String.init) ?? last.total.map(String.init) ?? "unknown"
        return "event_\(session)_\(millis)_\(counter)"
    }

    /// The same request can be printed as a `token_usage_record` and as an
    /// `event_msg` `last_token_usage`. Its time and own total identify it.
    private func requestKey(session: String, observed: Date, total: Int?) -> String {
        let second = Int64(observed.timeIntervalSince1970.rounded(.down))
        return "\(session)|\(second)|\(total.map(String.init) ?? "unknown")"
    }

    private func summed(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            if overflow { return nil }
            total = sum
        }
        return total
    }

    private func requestRecordId(
        payload: [String: Any],
        lineIndex: Int,
        observed: Date,
        usage: Usage
    ) -> String {
        if let response = payload["response_id"] as? String, !response.isEmpty {
            return "response_\(response)"
        }
        if let turn = payload["turn_id"] as? String, !turn.isEmpty {
            return "turn_\(turn)_\(Int(observed.timeIntervalSince1970))"
        }
        let total = usage.total.map(String.init) ?? "unknown"
        return "line_\(lineIndex)_\(Int(observed.timeIntervalSince1970))_\(total)"
    }
}
