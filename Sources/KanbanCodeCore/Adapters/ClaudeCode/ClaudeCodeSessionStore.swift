import Foundation

/// Implements SessionStore for Claude Code .jsonl files.
public final class ClaudeCodeSessionStore: SessionStore, @unchecked Sendable {

    public init() {}

    public func readTranscript(sessionPath: String) async throws -> [ConversationTurn] {
        try await TranscriptReader.readTurns(from: sessionPath)
    }

    public func forkSession(sessionPath: String, targetDirectory: String? = nil) async throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        let newSessionId = UUID().uuidString
        let dir = targetDirectory ?? (sessionPath as NSString).deletingLastPathComponent
        if let targetDirectory, !fileManager.fileExists(atPath: targetDirectory) {
            try fileManager.createDirectory(atPath: targetDirectory, withIntermediateDirectories: true)
        }
        let newPath = (dir as NSString).appendingPathComponent("\(newSessionId).jsonl")

        // Read, replace session IDs, write
        let url = URL(fileURLWithPath: sessionPath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let oldSessionId = (sessionPath as NSString).lastPathComponent
            .replacingOccurrences(of: ".jsonl", with: "")

        var lines: [String] = []
        for try await line in handle.bytes.lines {
            let replaced = line.replacingOccurrences(
                of: "\"\(oldSessionId)\"",
                with: "\"\(newSessionId)\""
            )
            lines.append(replaced)
        }

        try lines.joined(separator: "\n").write(
            toFile: newPath, atomically: true, encoding: .utf8
        )

        return newSessionId
    }

    public func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        // Backup
        let backupPath = sessionPath + ".bkp"
        try? fileManager.removeItem(atPath: backupPath)
        try fileManager.copyItem(atPath: sessionPath, toPath: backupPath)

        // Read lines up to the target line number
        let url = URL(fileURLWithPath: sessionPath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var keptLines: [String] = []
        var lineNumber = 0

        for try await line in handle.bytes.lines {
            lineNumber += 1
            keptLines.append(line)
            if lineNumber >= afterTurn.lineNumber {
                break
            }
        }

        try keptLines.joined(separator: "\n").write(
            toFile: sessionPath, atomically: true, encoding: .utf8
        )
    }

    public func searchSessions(query: String, paths: [String]) async throws -> [SearchResult] {
        let queryTerms = BM25Scorer.tokenize(query)
        guard !queryTerms.isEmpty else { return [] }

        struct DocInfo {
            let path: String
            let matchingTokens: [String]  // only tokens that match query terms
            let wordCount: Int            // total word count for BM25 doc length
            let snippet: String
            let modifiedTime: Date
        }

        var docs: [DocInfo] = []
        var globalTermFreqs: [String: Int] = [:]
        var totalWordCount = 0

        let fileManager = FileManager.default

        // Filter to existing files and sort by modification time (newest first)
        let validPaths: [(String, Date)] = paths.compactMap { path in
            guard fileManager.fileExists(atPath: path),
                  let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return (path, mtime)
        }.sorted { $0.1 > $1.1 }

        for (path, mtime) in validPaths {
            guard !Task.isCancelled else { break }

            // Stream through file, only keeping tokens that match query terms
            let (matchingTokens, wordCount, snippet) = extractMatchingTokens(
                from: path, queryTerms: queryTerms
            )
            guard wordCount > 0 else { continue }

            // Track document frequencies (which query terms appear in this doc)
            let uniqueTerms = Set(matchingTokens)
            for term in uniqueTerms {
                globalTermFreqs[term, default: 0] += 1
            }
            totalWordCount += wordCount

            docs.append(DocInfo(
                path: path,
                matchingTokens: matchingTokens,
                wordCount: wordCount,
                snippet: snippet,
                modifiedTime: mtime
            ))

            await Task.yield()
        }

        guard !docs.isEmpty else { return [] }
        let avgDocLength = Double(totalWordCount) / Double(docs.count)

        // Score each document
        var results: [SearchResult] = []
        for doc in docs {
            let boost = BM25Scorer.recencyBoost(modifiedTime: doc.modifiedTime)
            let score = BM25Scorer.score(
                terms: queryTerms,
                documentTokens: doc.matchingTokens,
                avgDocLength: avgDocLength,
                docCount: docs.count,
                docFreqs: globalTermFreqs,
                recencyBoost: boost
            )
            if score > 0 {
                results.append(SearchResult(sessionPath: doc.path, score: score, snippet: doc.snippet))
            }
        }

        return results.sorted { $0.score > $1.score }
    }

    /// Stream through a .jsonl file, extracting only tokens that match query terms.
    /// Returns (matchingTokens, totalWordCount, bestSnippet).
    /// Streams the entire file with no size limit — only matching tokens are kept in memory.
    private func extractMatchingTokens(
        from path: String,
        queryTerms: [String]
    ) -> (tokens: [String], wordCount: Int, snippet: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return ([], 0, "")
        }

        var matchingTokens: [String] = []
        var wordCount = 0
        var bestSnippet = ""
        var bestSnippetScore = 0

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            // Fast string check — skip lines that aren't user/assistant messages
            guard line.contains("\"type\"") else { continue }
            let lineStr = String(line)
            guard lineStr.contains("\"user\"") || lineStr.contains("\"assistant\"") else { continue }

            guard let lineData = lineStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String,
                  (type == "user" || type == "assistant"),
                  let text = JsonlParser.extractTextContent(from: obj) else { continue }

            // Tokenize and match — only keep tokens that match query terms
            let docTokens = text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && $0.count >= 2 }

            wordCount += docTokens.count

            for token in docTokens {
                if let matched = matchQueryTerm(token: token, queryTerms: queryTerms) {
                    matchingTokens.append(matched)
                }
            }

            // Track best snippet — check if this message has more query term matches
            let lower = text.lowercased()
            var snippetScore = 0
            for qt in queryTerms {
                if lower.contains(qt) { snippetScore += 1 }
            }
            if snippetScore > bestSnippetScore {
                bestSnippetScore = snippetScore
                bestSnippet = extractSnippet(from: text, queryTerms: queryTerms, role: type)
            }
        }

        return (matchingTokens, wordCount, bestSnippet)
    }

    /// Check if a document token matches any query term (exact or prefix match).
    private func matchQueryTerm(token: String, queryTerms: [String]) -> String? {
        for qt in queryTerms {
            if token == qt || token.hasPrefix(qt) || qt.hasPrefix(token) {
                return qt  // normalize to query term for TF counting
            }
        }
        return nil
    }

    /// Extract a snippet around the first query term match in text.
    private func extractSnippet(from text: String, queryTerms: [String], role: String) -> String {
        let lower = text.lowercased()
        for qt in queryTerms {
            if let range = lower.range(of: qt) {
                let idx = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let start = max(0, idx - 40)
                let end = min(text.count, idx + qt.count + 60)
                let startIdx = text.index(text.startIndex, offsetBy: start)
                let endIdx = text.index(text.startIndex, offsetBy: end)
                let prefix = start > 0 ? "..." : ""
                let suffix = end < text.count ? "..." : ""
                let snippet = text[startIdx..<endIdx].replacingOccurrences(of: "\n", with: " ")
                let label = role == "user" ? "You" : "Claude"
                return "\(label): \(prefix)\(snippet)\(suffix)"
            }
        }
        return String(text.prefix(100))
    }
}

public enum SessionStoreError: Error, LocalizedError {
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): "Session file not found: \(path)"
        }
    }
}
