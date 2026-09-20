import Foundation

/// Ingests CLI activity from OpenAI Codex (`~/.codex/sessions/`).
///
/// CRITICAL INVARIANT:
/// Codex reports cumulative session totals on every turn in `payload.info.total_token_usage`.
/// We must take the LAST recorded token usage per session, NEVER sum them across turns.
///
/// This adapter deliberately re-reads a rollout file from the start whenever it
/// changes, rather than resuming at a byte offset: the cumulative total and the
/// session metadata (`cwd`, `git_branch`, model) are established by the first
/// lines of the file, and only the total is superseded by later lines. A
/// file is skipped entirely when `(size, mtime)` are unchanged, which is the
/// common case for every rollout except the one currently being written.
public struct CodexAdapter: ActivityAdapter, Sendable {
    public let sourceIdentifier: String = "codex"
    public let baseURL: URL?

    public init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
        } else if TestHost.isActive {
            self.baseURL = nil
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.baseURL = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        }
    }

    public func collectActivities(watermarks: [String: ActivityWatermark]) async throws -> ActivityIngestResult {
        guard let baseURL, FileManager.default.fileExists(atPath: baseURL.path) else {
            return .empty
        }

        var records: [ActivityRecord] = []
        var updates: [ActivityWatermark] = []

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

            if let prior = watermarks[path], prior.isUnchanged(fileSize: size, modifiedAt: mtime) {
                continue
            }

            guard let data = try? Data(contentsOf: fileURL),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }

            var sessionId: String?
            var projectPath: String?
            var gitBranch: String?
            var model: String?
            var sessionStartedAt: Date?
            var lastEndedAt: Date?

            struct TokenUsage {
                var inputTokens: Int?
                var outputTokens: Int?
                var cacheReadTokens: Int?
                var cacheWriteTokens: Int?
                var totalTokens: Int?
            }
            var lastTokenUsage: TokenUsage?

            for line in content.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let lineData = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
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
                    if let ts = (payload["timestamp"] as? String).flatMap(parseDate) {
                        sessionStartedAt = ts
                    }
                } else if lineType == "event_msg", let payload = json["payload"] as? [String: Any] {
                    if let pType = payload["type"] as? String, pType == "token_count",
                       let info = payload["info"] as? [String: Any],
                       let totalUsage = info["total_token_usage"] as? [String: Any] {
                        // Absent is absent. Codex reports these together, so a
                        // missing one means an unexpected shape rather than a
                        // real zero, and the total is then unknown.
                        let input = totalUsage["input_tokens"] as? Int
                        let output = totalUsage["output_tokens"] as? Int
                        let cacheRead = totalUsage["cached_input_tokens"] as? Int
                        let cacheWrite = totalUsage["cache_write_input_tokens"] as? Int

                        let total: Int?
                        if let reported = totalUsage["total_tokens"] as? Int {
                            total = reported
                        } else if let input, let output, let cacheRead, let cacheWrite {
                            total = input + output + cacheRead + cacheWrite
                        } else {
                            total = nil
                        }

                        lastTokenUsage = TokenUsage(
                            inputTokens: input,
                            outputTokens: output,
                            cacheReadTokens: cacheRead,
                            cacheWriteTokens: cacheWrite,
                            totalTokens: total
                        )
                        if let ts = lineTimestamp {
                            lastEndedAt = ts
                        }
                    } else if let pType = payload["type"] as? String, pType == "turn_context",
                              let m = payload["model"] as? String {
                        model = m
                    }
                }
            }

            if let lastUsage = lastTokenUsage {
                let effectiveSessionId = sessionId ?? fileURL.deletingPathExtension().lastPathComponent
                let observed = lastEndedAt ?? sessionStartedAt ?? Date()

                records.append(ActivityRecord(
                    source: sourceIdentifier,
                    recordId: "codex_\(effectiveSessionId)",
                    sessionId: effectiveSessionId,
                    projectPath: projectPath,
                    gitBranch: gitBranch,
                    model: model,
                    observedAt: observed,
                    inputTokens: lastUsage.inputTokens,
                    outputTokens: lastUsage.outputTokens,
                    cacheReadTokens: lastUsage.cacheReadTokens,
                    cacheWriteTokens: lastUsage.cacheWriteTokens,
                    totalTokens: lastUsage.totalTokens
                ))
            }

            updates.append(ActivityWatermark(
                filePath: path,
                fileSize: size,
                modifiedAt: mtime,
                cursor: size
            ))
        }

        return ActivityIngestResult(records: records, watermarks: updates)
    }
}
