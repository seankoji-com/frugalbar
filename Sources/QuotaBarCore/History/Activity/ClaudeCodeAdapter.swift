import Foundation

/// Ingests CLI activity from Claude Code's `projects/` directory, located by
/// `defaultProjectsDirectory(environment:home:fileExists:)`.
/// Deduplicates records by `message.id` (or `requestId`) to avoid double-counting.
public struct ClaudeCodeAdapter: ActivityAdapter, Sendable {
    public let sourceIdentifier: String = "claude_code"
    public let baseURL: URL?

    public init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
        } else if TestHost.isActive {
            self.baseURL = nil
        } else {
            self.baseURL = Self.defaultProjectsDirectory(
                environment: ProcessInfo.processInfo.environment,
                home: FileManager.default.homeDirectoryForCurrentUser,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) }
            )
        }
    }

    /// Where Claude Code keeps session transcripts: the `projects` directory
    /// under the first of `$CLAUDE_CONFIG_DIR`, `~/.config/claude` and
    /// `~/.claude` that has one (see `CLIConfigLocations.claudeRoot`).
    static func defaultProjectsDirectory(
        environment: [String: String],
        home: URL,
        fileExists: (URL) -> Bool
    ) -> URL {
        CLIConfigLocations.claudeRoot(
            containing: "projects", environment: environment, home: home, fileExists: fileExists
        ).appendingPathComponent("projects", isDirectory: true)
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
        var incomplete = 0
        var inputDiagnostics: [ActivityInputDiagnostics] = []
        var consideredInputs: [String] = []

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

            // Where to resume. Appends resume at the last recorded line boundary;
            // anything else (truncation, in-place rewrite, a shrink) restarts at
            // zero, which is safe because records de-duplicate on `record_id`.
            var readFrom: Int64 = 0
            if let prior = watermarks[path] {
                if prior.isUnchanged(fileSize: size, modifiedAt: mtime) {
                    continue
                }
                if size > prior.fileSize, prior.cursor <= size {
                    readFrom = prior.cursor
                }
            }

            // A file that cannot be read is NOT recorded as read. Substituting
            // an empty chunk and then storing this size and mtime made the next
            // pass see the file as unchanged, so the unread part was never
            // retried. Leave it without a watermark so it is read again, and
            // say so.
            let chunk: AppendOnlyLog.Chunk
            do {
                chunk = try AppendOnlyLog.readIncrementally(at: fileURL, from: readFrom)
            } catch {
                skipped += 1
                inputDiagnostics.append(ActivityInputDiagnostics(
                    filePath: path, recordsObserved: 0, readFailure: true))
                continue
            }
            scanned += 1
            let malformedBefore = malformed
            let incompleteBefore = incomplete
            let recordsBefore = records.count

            // An unterminated final line is either a half-written record or a
            // complete one the writer never newline-terminated. Parse it if it
            // parses; a half-written line will fail here and be re-read later.
            var lines = chunk.lines
            var cursor = chunk.newCursor
            if !chunk.tail.isEmpty,
               let tailData = chunk.tail.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: tailData)) is [String: Any] {
                lines.append(chunk.tail)
                cursor = size
            }

            // Re-reads after a rewrite re-emit lines already stored; the DB's
            // `(source, record_id)` primary key absorbs those. This set only
            // stops the same line twice inside one chunk, which the on-disk
            // format does produce.
            var seenRecordIds = Set<String>()

            for line in lines {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    malformed += 1
                    continue
                }

                guard let message = json["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else {
                    continue
                }

                guard let recordId = (message["id"] as? String) ?? (json["requestId"] as? String) ?? (json["uuid"] as? String),
                      !recordId.isEmpty else {
                    malformed += 1
                    continue
                }

                if seenRecordIds.contains(recordId) {
                    continue
                }
                seenRecordIds.insert(recordId)

                let sessionId = (json["sessionId"] as? String) ?? (message["sessionId"] as? String) ?? fileURL.deletingPathExtension().lastPathComponent
                let projectPath = (json["cwd"] as? String)
                let gitBranch = (json["gitBranch"] as? String)
                let model = (json["model"] as? String) ?? (message["model"] as? String)

                var recordDate = Date()
                if let tsStr = (json["timestamp"] as? String) ?? (message["timestamp"] as? String),
                   let d = parseDate(tsStr) {
                    recordDate = d
                }

                // Absent means absent: a missing field stays `nil` so it is never
                // counted as a measured zero. Claude's cache reads and writes
                // are additive to input; `ActivityRecord` derives the total
                // from whatever was actually reported.
                let input = nonNegative(usage["input_tokens"], malformed: &malformed)
                let output = nonNegative(usage["output_tokens"], malformed: &malformed)
                let cacheRead = nonNegative(usage["cache_read_input_tokens"], malformed: &malformed)
                let cacheWrite = nonNegative(usage["cache_creation_input_tokens"], malformed: &malformed)
                let record = ActivityRecord(
                    source: sourceIdentifier,
                    recordId: recordId,
                    sessionId: sessionId,
                    projectPath: projectPath,
                    gitBranch: gitBranch,
                    model: model,
                    observedAt: recordDate,
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    semantics: .additive
                )
                if record.totalKind == .partial || record.totalKind == .unknown {
                    incomplete += 1
                }
                records.append(record)
            }

            updates.append(ActivityWatermark(
                filePath: path,
                fileSize: size,
                modifiedAt: mtime,
                cursor: cursor
            ))
            inputDiagnostics.append(ActivityInputDiagnostics(
                filePath: path,
                malformedRecords: malformed - malformedBefore,
                incompleteRecords: incomplete - incompleteBefore,
                recordsObserved: records.count - recordsBefore,
                coverage: readFrom > 0 ? .appendedRegion : .wholeInput))
        }

        return ActivityIngestResult(
            records: records,
            watermarks: updates,
            diagnostics: ActivityPassDiagnostics(
                scannedInputs: scanned,
                skippedInputs: skipped,
                malformedRecords: malformed,
                incompleteRecords: incomplete,
                recordsObserved: records.count
            ),
            inputDiagnostics: inputDiagnostics,
            inputsConsidered: consideredInputs
        )
    }

    private func nonNegative(_ value: Any?, malformed: inout Int) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let exact = TokenCountParsing.nonNegative(value) else {
            malformed += 1
            return nil
        }
        return exact
    }
}
