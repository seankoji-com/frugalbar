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

    /// Where Claude Code keeps session transcripts: `$CLAUDE_CONFIG_DIR` when
    /// set, else `~/.config/claude` if it has a `projects` directory (newer
    /// installs), else the legacy `~/.claude`.
    ///
    /// An app launched from Finder or at login does not inherit shell
    /// variables, so the environment only applies when started from a shell.
    static func defaultProjectsDirectory(
        environment: [String: String],
        home: URL,
        fileExists: (URL) -> Bool
    ) -> URL {
        if let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces),
           !configured.isEmpty {
            let root = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
            return root.appendingPathComponent("projects", isDirectory: true)
        }
        let xdg = home.appendingPathComponent(".config/claude/projects", isDirectory: true)
        if fileExists(xdg) { return xdg }
        return home.appendingPathComponent(".claude/projects", isDirectory: true)
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

            let chunk = (try? AppendOnlyLog.readIncrementally(at: fileURL, from: readFrom))
                ?? AppendOnlyLog.Chunk(lines: [], newCursor: readFrom, tail: "")

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
                    continue
                }

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

                // Absent means absent: a missing field stays `nil` so it is never
                // counted as a measured zero. `ActivityRecord` derives the total
                // from whatever was actually reported.
                records.append(ActivityRecord(
                    source: sourceIdentifier,
                    recordId: recordId,
                    sessionId: sessionId,
                    projectPath: projectPath,
                    gitBranch: gitBranch,
                    model: model,
                    observedAt: recordDate,
                    inputTokens: usage["input_tokens"] as? Int,
                    outputTokens: usage["output_tokens"] as? Int,
                    cacheReadTokens: usage["cache_read_input_tokens"] as? Int,
                    cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int
                ))
            }

            updates.append(ActivityWatermark(
                filePath: path,
                fileSize: size,
                modifiedAt: mtime,
                cursor: cursor
            ))
        }

        return ActivityIngestResult(records: records, watermarks: updates)
    }
}
