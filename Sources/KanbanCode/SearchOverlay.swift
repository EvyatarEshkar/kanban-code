import SwiftUI
import KanbanCodeCore

struct SearchOverlay: View {
    @Binding var isPresented: Bool
    let cards: [KanbanCodeCard]
    let sessionStore: SessionStore
    var onSelectCard: (KanbanCodeCard) -> Void = { _ in }
    var onResumeCard: (KanbanCodeCard) -> Void = { _ in }
    var onForkCard: (KanbanCodeCard) -> Void = { _ in }
    var onCheckpointCard: (KanbanCodeCard) -> Void = { _ in }

    @State private var query = ""
    @State private var searchResults: [SearchResultItem] = []
    @State private var isDeepSearching = false
    @State private var selectedId: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.app(.title3))
                    .foregroundStyle(.secondary)
                TextField("Search sessions...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.app(.title3))
                    .focused($isSearchFocused)
                    .onSubmit {
                        Task { await deepSearch() }
                    }

                if isDeepSearching {
                    ProgressView()
                        .controlSize(.small)
                }

                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                Button("Esc") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(16)

            Divider()

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if query.isEmpty {
                            recentSessionsView
                        } else if !searchResults.isEmpty {
                            ForEach(searchResults) { result in
                                SearchResultRow(result: result, queryTerms: queryTerms, isHighlighted: result.id == selectedId)
                                    .onTapGesture {
                                        if let card = result.card {
                                            onSelectCard(card)
                                            isPresented = false
                                        }
                                    }
                                    .contextMenu {
                                        if let card = result.card {
                                            searchCardContextMenu(for: card)
                                        }
                                    }
                            }
                        } else if !isDeepSearching {
                            filteredCardsView
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedId) { _, newId in
                    if let newId {
                        withAnimation {
                            proxy.scrollTo(newId, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 600, maxHeight: 500)
        .glassOverlay()
        .onAppear {
            isSearchFocused = true
        }
        .onExitCommand {
            isPresented = false
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.return) {
            if selectedId != nil {
                selectCurrentItem()
            } else {
                Task { await deepSearch() }
            }
            return .handled
        }
        .onChange(of: query) { _, newValue in
            selectedId = nil
            updateFilter(newValue)
        }
    }

    private var queryTerms: [String] {
        query.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    /// All visible item IDs in current order
    private var visibleIds: [String] {
        if query.isEmpty {
            return Array(cards.prefix(10)).map { $0.id }
        } else if !searchResults.isEmpty {
            return searchResults.map(\.id)
        } else {
            return filterCards(query: query).map { $0.id }
        }
    }

    private func moveSelection(by offset: Int) {
        let ids = visibleIds
        guard !ids.isEmpty else { return }

        if let currentId = selectedId, let currentIdx = ids.firstIndex(of: currentId) {
            let newIdx = min(max(currentIdx + offset, 0), ids.count - 1)
            selectedId = ids[newIdx]
        } else {
            selectedId = offset > 0 ? ids.first : ids.last
        }
    }

    private func selectCurrentItem() {
        guard let currentId = selectedId else { return }

        if query.isEmpty {
            if let card = cards.prefix(10).first(where: { $0.id == currentId }) {
                onSelectCard(card)
                isPresented = false
            }
        } else if !searchResults.isEmpty {
            if let result = searchResults.first(where: { $0.id == currentId }),
               let card = result.card {
                onSelectCard(card)
                isPresented = false
            }
        } else {
            let filtered = filterCards(query: query)
            if let card = filtered.first(where: { $0.id == currentId }) {
                onSelectCard(card)
                isPresented = false
            } else {
                // No match — trigger deep search
                Task { await deepSearch() }
            }
        }
    }

    private var recentSessionsView: some View {
        Group {
            Text("Recent Sessions")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            ForEach(Array(cards.prefix(10))) { card in
                let cardId = card.id
                SearchCardRow(card: card, queryTerms: [], isHighlighted: cardId == selectedId)
                    .id(cardId)
                    .onTapGesture {
                        onSelectCard(card)
                        isPresented = false
                    }
                    .contextMenu { searchCardContextMenu(for: card) }
            }
        }
    }

    private var filteredCardsView: some View {
        Group {
            let filtered = filterCards(query: query)
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                    Text("Press Enter to deep search .jsonl files")
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            } else {
                ForEach(filtered) { card in
                    let cardId = card.id
                    SearchCardRow(card: card, queryTerms: queryTerms, isHighlighted: cardId == selectedId)
                        .id(cardId)
                        .onTapGesture {
                            onSelectCard(card)
                            isPresented = false
                        }
                        .contextMenu { searchCardContextMenu(for: card) }
                }
            }
        }
    }

    private func filterCards(query: String) -> [KanbanCodeCard] {
        let terms = queryTerms
        guard !terms.isEmpty else { return [] }
        let activeColumns: Set<KanbanCodeColumn> = [.inProgress, .waiting, .inReview, .done]

        return cards
            .compactMap { card -> (KanbanCodeCard, Double)? in
                let title = card.displayTitle.lowercased()
                let project = (card.projectName ?? "").lowercased()
                let branch = (card.link.worktreeLink?.branch ?? "").lowercased()
                let other = "\(card.link.projectPath ?? "") \(card.session?.firstPrompt ?? "") \(card.link.promptBody ?? "") \(card.link.sessionLink?.sessionId ?? "") \(card.link.id)".lowercased()

                let titleWords = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
                let projectWords = project.split { !$0.isLetter && !$0.isNumber }.map(String.init)

                var score = 0.0
                for term in terms {
                    let s = Self.termScore(term, titleWords: titleWords, title: title, projectWords: projectWords, project: project, branch: branch, other: other)
                    if s > 0 {
                        score += s
                    } else if term.count >= 2, Self.fuzzyInitials(term, words: titleWords) {
                        score += 10 // "kp" → Kanban Projects
                    } else {
                        return nil
                    }
                }

                if activeColumns.contains(card.column) { score += 20 }

                // Recency bonus: up to +5 for very recent, decaying over 7 days
                let lastActive = card.link.lastActivity ?? card.link.updatedAt
                let age = Date.now.timeIntervalSince(lastActive)
                let maxAge: TimeInterval = 7 * 24 * 3600
                if age < maxAge {
                    score += 5.0 * (1.0 - age / maxAge)
                }

                return (card, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Score a single search term against card fields.
    /// Word-start matches score much higher than mid-word matches.
    private static func termScore(_ term: String, titleWords: [String], title: String, projectWords: [String], project: String, branch: String, other: String) -> Double {
        // Title: word-start match (best)
        for word in titleWords {
            if word == term { return 15 }       // exact word
            if word.hasPrefix(term) { return 12 } // word prefix
        }
        if title.contains(term) { return 6 }   // mid-word substring

        // Project: word-start match
        for word in projectWords {
            if word == term { return 8 }
            if word.hasPrefix(term) { return 7 }
        }
        if project.contains(term) { return 4 }

        // Branch / other
        if branch.contains(term) { return 3 }
        if other.contains(term) { return 1 }
        return 0
    }

    /// Check if each character of `term` matches the first letter of consecutive words.
    /// e.g. "kp" matches ["kanban", "projects"], "kl3" matches ["kanban", "loop", "3"]
    private static func fuzzyInitials(_ term: String, words: [String]) -> Bool {
        var i = term.startIndex
        for word in words {
            guard i < term.endIndex else { break }
            if let first = word.first, first == term[i] {
                i = term.index(after: i)
            }
        }
        return i == term.endIndex
    }

    @ViewBuilder
    private func searchCardContextMenu(for card: KanbanCodeCard) -> some View {
        Button {
            onResumeCard(card)
            isPresented = false
        } label: {
            Label("Resume Session", systemImage: "play.fill")
        }
        .disabled(card.link.sessionLink == nil)

        Button {
            onForkCard(card)
            isPresented = false
        } label: {
            Label("Fork Session", systemImage: "arrow.branch")
        }
        .disabled(card.link.sessionLink?.sessionPath == nil)

        Button {
            onCheckpointCard(card)
            isPresented = false
        } label: {
            Label("Checkpoint / Restore", systemImage: "clock.arrow.circlepath")
        }
        .disabled(card.link.sessionLink?.sessionPath == nil)
    }

    private func updateFilter(_ query: String) {
        // Cancel any in-progress deep search when query changes
        searchTask?.cancel()
        searchTask = nil
        searchResults = []
        isDeepSearching = false
    }

    private func deepSearch() async {
        guard !query.isEmpty else { return }

        // Cancel previous search and wait for it to stop
        if let old = searchTask {
            old.cancel()
            _ = await old.value
            searchTask = nil
        }

        let currentQuery = query
        let currentCards = cards
        let t0 = ContinuousClock.now
        KanbanCodeLog.info("search", "deepSearch START query='\(currentQuery)' cards=\(currentCards.count)")

        // Build path→card lookup once
        var cardByPath: [String: KanbanCodeCard] = [:]
        for card in currentCards {
            if let p = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath {
                cardByPath[p] = card
            }
        }

        let task = Task { @MainActor in
            isDeepSearching = true
            defer {
                isDeepSearching = false
                KanbanCodeLog.info("search", "deepSearch END query='\(currentQuery)' elapsed=\(t0.duration(to: .now)) cancelled=\(Task.isCancelled)")
            }

            let paths = Array(cardByPath.keys)
            KanbanCodeLog.info("search", "deepSearch: \(paths.count) session paths to search")

            do {
                try await sessionStore.searchSessionsStreaming(
                    query: currentQuery, paths: paths
                ) { [cardByPath] results in
                    let maxScore = results.first?.score ?? 1.0
                    searchResults = results.map { result in
                        SearchResultItem(
                            id: result.sessionPath,
                            card: cardByPath[result.sessionPath],
                            score: result.score,
                            maxScore: maxScore,
                            snippets: result.snippets
                        )
                    }
                }
            } catch is CancellationError {
                KanbanCodeLog.info("search", "deepSearch cancelled after \(t0.duration(to: .now))")
            } catch {
                KanbanCodeLog.error("search", "deepSearch error: \(error)")
            }
        }
        searchTask = task
        await task.value
    }
}

struct SearchResultItem: Identifiable {
    let id: String
    let card: KanbanCodeCard?
    let score: Double
    let maxScore: Double
    let snippets: [String]
}

struct SearchCardRow: View {
    let card: KanbanCodeCard
    let queryTerms: [String]
    var isHighlighted: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HighlightedText(text: card.displayTitle, terms: queryTerms)
                    .font(.app(.body))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let project = card.projectName {
                        Text(project)
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Text(card.relativeTime)
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(card.column.displayName)
                .font(.app(.caption2))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            isHighlighted ? Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }
}

struct SearchResultRow: View {
    let result: SearchResultItem
    let queryTerms: [String]
    var isHighlighted: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let card = result.card {
                        HighlightedText(text: card.displayTitle, terms: queryTerms)
                            .font(.app(.body))
                            .lineLimit(1)
                    } else {
                        Text((result.id as NSString).lastPathComponent)
                            .font(.app(.body))
                            .lineLimit(1)
                    }
                    Spacer()
                }

                // Snippets (up to 3)
                ForEach(Array(result.snippets.enumerated()), id: \.offset) { _, snippet in
                    HighlightedText(text: snippet, terms: queryTerms)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            // Relevance bar — horizontal, thick, right side
            let ratio = result.maxScore > 0 ? result.score / result.maxScore : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.1))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 50 * ratio)
            }
            .frame(width: 50, height: 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }
}

/// Highlights query terms in text with yellow background.
struct HighlightedText: View {
    let text: String
    let terms: [String]

    var body: some View {
        if terms.isEmpty {
            Text(text)
        } else {
            Text(attributedString)
        }
    }

    private var attributedString: AttributedString {
        var attr = AttributedString(text)
        let lower = text.lowercased()
        let words = lower.split { !$0.isLetter && !$0.isNumber }

        for term in terms {
            // Try substring matching first
            var foundSubstring = false
            var searchStart = lower.startIndex
            while let range = lower.range(of: term, range: searchStart..<lower.endIndex) {
                foundSubstring = true
                let attrStart = AttributedString.Index(range.lowerBound, within: attr)
                let attrEnd = AttributedString.Index(range.upperBound, within: attr)
                if let start = attrStart, let end = attrEnd {
                    attr[start..<end].backgroundColor = .yellow.opacity(0.3)
                }
                searchStart = range.upperBound
            }

            // Fall back to fuzzy initials highlighting
            if !foundSubstring && term.count >= 2 {
                var termIdx = term.startIndex
                for word in words {
                    guard termIdx < term.endIndex else { break }
                    if let first = word.first, first == term[termIdx] {
                        let charIdx = word.startIndex
                        let nextIdx = lower.index(after: charIdx)
                        if let attrStart = AttributedString.Index(charIdx, within: attr),
                           let attrEnd = AttributedString.Index(nextIdx, within: attr) {
                            attr[attrStart..<attrEnd].backgroundColor = .yellow.opacity(0.3)
                        }
                        termIdx = term.index(after: termIdx)
                    }
                }
            }
        }
        return attr
    }
}
