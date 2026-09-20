import Foundation

/// Incremental reader for newline-delimited, append-only files.
enum AppendOnlyLog {
    struct Chunk {
        let lines: [String]
        /// Cursor to record for next time, always on a line boundary.
        let newCursor: Int64
        /// Whatever followed the last newline — possibly a half-written record,
        /// possibly a complete line the writer simply did not terminate. The
        /// caller decides; this reader cannot know which.
        let tail: String
    }

    /// Reads `url` from `cursor` to EOF, returning only complete lines plus the
    /// cursor to persist.
    ///
    /// A trailing unterminated fragment is returned separately as `tail` rather
    /// than consumed: the cursor stops at the last newline so the fragment is
    /// re-read once the writer has finished it. Consuming it blindly would
    /// advance past a record that had not been fully written.
    static func readIncrementally(at url: URL, from cursor: Int64) throws -> Chunk {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if cursor > 0 {
            try handle.seek(toOffset: UInt64(cursor))
        }

        guard let data = try handle.readToEnd(), !data.isEmpty else {
            return Chunk(lines: [], newCursor: cursor, tail: "")
        }

        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            // Nothing but an unterminated fragment since the cursor.
            return Chunk(lines: [], newCursor: cursor, tail: String(decoding: data, as: UTF8.self))
        }

        let consumed = Int64(data.distance(from: data.startIndex, to: lastNewline) + 1)
        let complete = data[data.startIndex...lastNewline]
        let remainder = data[data.index(after: lastNewline)...]

        let lines = String(decoding: complete, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return Chunk(
            lines: lines,
            newCursor: cursor + consumed,
            tail: String(decoding: remainder, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
