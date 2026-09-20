import Foundation

/// Ingests CLI activity from Claude Code (`~/.claude/projects/`).
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
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.baseURL = home.appendingPathComponent(".claude/projects", isDirectory: true)
        }
    }

    public func collectActivities(since watermarkMtime: Int64?) async throws -> (records: [ActivityRecord], maxMtime: Int64?) {
        guard let baseURL, FileManager.default.fileExists(atPath: baseURL.path) else {
            return ([], nil)
        }

        var results: [ActivityRecord] = []
        var seenRecordIds = Set<String>()
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

            for line in content.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let lineData = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                // Check for message and usage
                guard let message = json["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else {
                    continue
                }

                guard let recordId = (message["id"] as? String) ?? (json["requestId"] as? String) ?? (json["uuid"] as? String),
                      !recordId.isEmpty else {
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

                let inputTokens = (usage["input_tokens"] as? Int) ?? 0
                let outputTokens = (usage["output_tokens"] as? Int) ?? 0
                let cacheReadTokens = (usage["cache_read_input_tokens"] as? Int) ?? 0
                let cacheWriteTokens = (usage["cache_creation_input_tokens"] as? Int) ?? 0

                results.append(ActivityRecord(
                    source: sourceIdentifier,
                    recordId: recordId,
                    sessionId: sessionId,
                    projectPath: projectPath,
                    gitBranch: gitBranch,
                    model: model,
                    observedAt: recordDate,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: cacheReadTokens,
                    cacheWriteTokens: cacheWriteTokens
                ))
            }
        }

        return (results, highestMtime)
    }
}
