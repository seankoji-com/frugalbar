import Foundation

/// Ingests CLI activity from OpenAI Codex (`~/.codex/sessions/`).
///
/// CRITICAL INVARIANT:
/// Codex reports cumulative session totals on every turn in `payload.info.total_token_usage`.
/// We must take the LAST recorded token usage per session, NEVER sum them across turns.
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

    public func collectActivities(since watermarkMtime: Int64?) async throws -> (records: [ActivityRecord], maxMtime: Int64?) {
        guard let baseURL, FileManager.default.fileExists(atPath: baseURL.path) else {
            return ([], nil)
        }

        var highestMtime: Int64? = watermarkMtime
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoStandard = ISO8601DateFormatter()
        isoStandard.formatOptions = [.withInternetDateTime]

        func parseDate(_ str: String) -> Date? {
            isoWithFraction.date(from: str) ?? isoStandard.date(from: str)
        }

        var results: [ActivityRecord] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "jsonl" else { continue }

            let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard resourceValues?.isRegularFile == true else { continue }

            if let modDate = resourceValues?.contentModificationDate {
                let mtime = Int64(modDate.timeIntervalSince1970)
                if let watermark = watermarkMtime, mtime <= watermark {
                    continue
                }
                if highestMtime == nil || mtime > highestMtime! {
                    highestMtime = mtime
                }
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
                var inputTokens: Int = 0
                var outputTokens: Int = 0
                var cacheReadTokens: Int = 0
                var cacheWriteTokens: Int = 0
                var totalTokens: Int = 0
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
                        let input = (totalUsage["input_tokens"] as? Int) ?? 0
                        let output = (totalUsage["output_tokens"] as? Int) ?? 0
                        let cacheRead = (totalUsage["cached_input_tokens"] as? Int) ?? 0
                        let cacheWrite = (totalUsage["cache_write_input_tokens"] as? Int) ?? 0
                        let total = (totalUsage["total_tokens"] as? Int) ?? (input + output + cacheRead + cacheWrite)

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

                results.append(ActivityRecord(
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
        }

        return (results, highestMtime)
    }
}
