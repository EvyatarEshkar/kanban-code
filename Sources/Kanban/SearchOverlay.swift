import SwiftUI
import KanbanCore

struct SearchOverlay: View {
    @Binding var isPresented: Bool
    let cards: [KanbanCard]
    var onSelectCard: (KanbanCard) -> Void = { _ in }

    @State private var query = ""
    @State private var searchResults: [SearchResultItem] = []
    @State private var isDeepSearching = false
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sessions...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if query.isEmpty {
                        recentSessionsIndexed
                    } else if !searchResults.isEmpty {
                        ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, result in
                            SearchResultRow(result: result, queryTerms: queryTerms, isHighlighted: index == selectedIndex)
                                .onTapGesture {
                                    if let card = result.card {
                                        onSelectCard(card)
                                        isPresented = false
                                    }
                                }
                        }
                    } else if !isDeepSearching {
                        filteredCardsIndexed
                    }
                }
                .padding(8)
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
            selectedIndex = min(selectedIndex + 1, visibleItemCount - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.return) {
            selectCurrentItem()
            return .handled
        }
        .onChange(of: query) { _, newValue in
            selectedIndex = 0
            updateFilter(newValue)
        }
    }

    private var queryTerms: [String] {
        query.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    private var visibleItemCount: Int {
        if query.isEmpty {
            return min(cards.count, 10)
        } else if !searchResults.isEmpty {
            return searchResults.count
        } else {
            return filterCards(query: query).count
        }
    }

    private func selectCurrentItem() {
        if query.isEmpty {
            let recent = Array(cards.prefix(10))
            guard selectedIndex < recent.count else { return }
            onSelectCard(recent[selectedIndex])
            isPresented = false
        } else if !searchResults.isEmpty {
            guard selectedIndex < searchResults.count,
                  let card = searchResults[selectedIndex].card else { return }
            onSelectCard(card)
            isPresented = false
        } else {
            let filtered = filterCards(query: query)
            guard selectedIndex < filtered.count else {
                // No filtered results — trigger deep search
                Task { await deepSearch() }
                return
            }
            onSelectCard(filtered[selectedIndex])
            isPresented = false
        }
    }

    private var recentSessionsIndexed: some View {
        Group {
            Text("Recent Sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            ForEach(Array(cards.prefix(10).enumerated()), id: \.element.id) { index, card in
                SearchCardRow(card: card, queryTerms: [], isHighlighted: index == selectedIndex)
                    .onTapGesture {
                        onSelectCard(card)
                        isPresented = false
                    }
            }
        }
    }

    private var filteredCardsIndexed: some View {
        Group {
            let filtered = filterCards(query: query)
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                    Text("Press Enter to deep search .jsonl files")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            } else {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, card in
                    SearchCardRow(card: card, queryTerms: queryTerms, isHighlighted: index == selectedIndex)
                        .onTapGesture {
                            onSelectCard(card)
                            isPresented = false
                        }
                }
            }
        }
    }

    private func filterCards(query: String) -> [KanbanCard] {
        let terms = queryTerms
        guard !terms.isEmpty else { return [] }
        return cards.filter { card in
            let text = "\(card.displayTitle) \(card.projectName ?? "") \(card.link.worktreeLink?.branch ?? "")".lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
    }

    private func updateFilter(_ query: String) {
        searchResults = []
    }

    private func deepSearch() async {
        guard !query.isEmpty else { return }
        isDeepSearching = true
        defer { isDeepSearching = false }

        let paths = cards.compactMap { $0.link.sessionLink?.sessionPath ?? $0.session?.jsonlPath }
        let store = ClaudeCodeSessionStore()

        do {
            let results = try await store.searchSessions(query: query, paths: paths)
            searchResults = results.map { result in
                let card = cards.first { ($0.link.sessionLink?.sessionPath ?? $0.session?.jsonlPath) == result.sessionPath }
                return SearchResultItem(
                    id: result.sessionPath,
                    card: card,
                    score: result.score,
                    snippet: result.snippet
                )
            }
        } catch {
            // Silently fail
        }
    }
}

struct SearchResultItem: Identifiable {
    let id: String
    let card: KanbanCard?
    let score: Double
    let snippet: String
}

struct SearchCardRow: View {
    let card: KanbanCard
    let queryTerms: [String]
    var isHighlighted: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HighlightedText(text: card.displayTitle, terms: queryTerms)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let project = card.projectName {
                        Text(project)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(card.relativeTime)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(card.column.displayName)
                .font(.caption2)
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
                if let card = result.card {
                    HighlightedText(text: card.displayTitle, terms: queryTerms)
                        .font(.body)
                        .lineLimit(1)
                } else {
                    Text((result.id as NSString).lastPathComponent)
                        .font(.body)
                        .lineLimit(1)
                }

                HighlightedText(text: result.snippet, terms: queryTerms)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer()

            // Relevance bar (vertical on the right)
            let normalizedScore = min(result.score / 10.0, 1.0)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.4))
                .frame(width: 4, height: 28 * normalizedScore)
                .frame(height: 28, alignment: .bottom)
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

/// Highlights query terms in text with bold styling.
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
        for term in terms {
            var searchStart = lower.startIndex
            while let range = lower.range(of: term, range: searchStart..<lower.endIndex) {
                let attrStart = AttributedString.Index(range.lowerBound, within: attr)
                let attrEnd = AttributedString.Index(range.upperBound, within: attr)
                if let start = attrStart, let end = attrEnd {
                    attr[start..<end].backgroundColor = .yellow.opacity(0.3)
                    attr[start..<end].font = .body.bold()
                }
                searchStart = range.upperBound
            }
        }
        return attr
    }
}
