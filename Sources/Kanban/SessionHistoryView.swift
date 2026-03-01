import SwiftUI
import AppKit
import KanbanCore

// MARK: - Force dark scrollbar on the history view

struct DarkScrollbarModifier: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.enclosingScrollView?.scrollerStyle = .overlay
            view.enclosingScrollView?.appearance = NSAppearance(named: .darkAqua)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SessionHistoryView: View {
    let turns: [ConversationTurn]
    let isLoading: Bool
    var checkpointMode: Bool = false
    var hasMoreTurns: Bool = false
    var isLoadingMore: Bool = false
    var onCancelCheckpoint: (() -> Void)?
    var onSelectTurn: ((ConversationTurn) -> Void)?
    var onLoadMore: (() -> Void)?

    @State private var hoveredTurnIndex: Int?
    @State private var isAtBottom = true
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var activeQuery = ""  // debounced, min 2 chars
    @State private var searchMatchIndices: [Int] = []
    @State private var currentMatchPosition: Int = 0
    @State private var searchDebounceTask: Task<Void, Never>?

    private static let maxSearchResults = 200

    /// Turns to display: either search results or all loaded turns.
    private var displayedTurns: [ConversationTurn] {
        if !activeQuery.isEmpty {
            let query = activeQuery.lowercased()
            var results: [ConversationTurn] = []
            for turn in turns {
                if turn.textPreview.lowercased().contains(query)
                    || turn.contentBlocks.contains(where: { $0.text.lowercased().contains(query) }) {
                    results.append(turn)
                    if results.count >= Self.maxSearchResults { break }
                }
            }
            return results
        }
        return turns
    }

    var body: some View {
        if isLoading {
            VStack {
                ProgressView()
                    .controlSize(.small)
                Text("Loading conversation...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if turns.isEmpty {
            VStack {
                Image(systemName: "text.bubble")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No conversation history")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .top) {
                Color(white: 0.08)
                    .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if checkpointMode {
                                checkpointBanner
                            }

                            // "Load earlier" button
                            if hasMoreTurns && activeQuery.isEmpty {
                                Button {
                                    onLoadMore?()
                                } label: {
                                    HStack(spacing: 4) {
                                        if isLoadingMore {
                                            ProgressView()
                                                .controlSize(.mini)
                                        } else {
                                            Image(systemName: "arrow.up")
                                                .font(.caption2)
                                        }
                                        Text("Load 80 earlier turns")
                                            .font(.caption)
                                    }
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoadingMore)
                                .id("load-more")
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(displayedTurns, id: \.index) { turn in
                                    TurnBlockView(
                                        turn: turn,
                                        checkpointMode: checkpointMode,
                                        isHovered: hoveredTurnIndex == turn.index,
                                        isDimmed: checkpointMode && hoveredTurnIndex != nil && turn.index > hoveredTurnIndex!,
                                        highlightText: activeQuery.isEmpty ? nil : activeQuery
                                    )
                                    .id(turn.index)
                                    .onHover { isHovering in
                                        if checkpointMode {
                                            hoveredTurnIndex = isHovering ? turn.index : nil
                                        }
                                    }
                                    .onTapGesture {
                                        if checkpointMode {
                                            onSelectTurn?(turn)
                                        }
                                    }
                                }
                                Color.clear.frame(height: 30).id("bottom-anchor")
                            }
                            .padding(.top, 8)
                            .padding(.horizontal, 12)
                        }
                        .background(DarkScrollbarModifier())
                        .background(ScrollBottomDetector(isAtBottom: $isAtBottom))
                    }
                    .onAppear { scrollToBottom(proxy: proxy, force: true) }
                    .onChange(of: turns.count) { scrollToBottom(proxy: proxy) }
                    .onChange(of: currentMatchPosition) {
                        guard !searchMatchIndices.isEmpty,
                              currentMatchPosition < searchMatchIndices.count else { return }
                        let idx = searchMatchIndices[currentMatchPosition]
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }

                // Search overlay
                if showSearch {
                    searchBar
                }
            }
            .background {
                // Hidden buttons for keyboard shortcuts
                Button("") {
                    showSearch = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()

                Button("") { dismissSearch() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .hidden()
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))

            TextField("Search history...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
                .onSubmit { navigateSearch(forward: true) }
                .onChange(of: searchText) { scheduleSearch() }

            if !activeQuery.isEmpty {
                if searchMatchIndices.isEmpty {
                    Text("0 results")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    Text("\(currentMatchPosition + 1)/\(searchMatchIndices.count)\(searchMatchIndices.count >= Self.maxSearchResults ? "+" : "")")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))

                    Button { navigateSearch(forward: false) } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))

                    Button { navigateSearch(forward: true) } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                }
            }

            Button { dismissSearch() } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(white: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func scheduleSearch() {
        searchDebounceTask?.cancel()

        // Clear immediately if empty
        if searchText.isEmpty {
            activeQuery = ""
            searchMatchIndices = []
            currentMatchPosition = 0
            return
        }

        // Require at least 2 chars
        guard searchText.count >= 2 else { return }

        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            activeQuery = searchText
            updateSearchMatches()
        }
    }

    private func updateSearchMatches() {
        guard !activeQuery.isEmpty else {
            searchMatchIndices = []
            currentMatchPosition = 0
            return
        }
        let query = activeQuery.lowercased()
        var indices: [Int] = []
        for turn in turns {
            if turn.textPreview.lowercased().contains(query)
                || turn.contentBlocks.contains(where: { $0.text.lowercased().contains(query) }) {
                indices.append(turn.index)
                if indices.count >= Self.maxSearchResults { break }
            }
        }
        searchMatchIndices = indices
        currentMatchPosition = max(0, indices.count - 1)
    }

    private func navigateSearch(forward: Bool) {
        guard !searchMatchIndices.isEmpty else { return }
        if forward {
            currentMatchPosition = (currentMatchPosition + 1) % searchMatchIndices.count
        } else {
            currentMatchPosition = (currentMatchPosition - 1 + searchMatchIndices.count) % searchMatchIndices.count
        }
    }

    private func dismissSearch() {
        searchDebounceTask?.cancel()
        showSearch = false
        searchText = ""
        activeQuery = ""
        searchMatchIndices = []
        currentMatchPosition = 0
    }

    private var checkpointBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
            Text("Click a turn to restore to. Everything after will be removed.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Button {
                onCancelCheckpoint?()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .help("Cancel checkpoint mode")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15))
    }

    private func scrollToBottom(proxy: ScrollViewProxy, force: Bool = false) {
        guard activeQuery.isEmpty else { return }
        guard force || isAtBottom else { return }
        // Use a task with small delay so layout completes first,
        // then scroll twice to handle late layout updates
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
            try? await Task.sleep(for: .milliseconds(100))
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }
}

// MARK: - Turn rendering

struct TurnBlockView: View {
    let turn: ConversationTurn
    var checkpointMode: Bool = false
    var isHovered: Bool = false
    var isDimmed: Bool = false
    var highlightText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if turn.role == "user" {
                userTurnView
            } else {
                assistantTurnView
            }
        }
        .opacity(isDimmed ? 0.3 : 1.0)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(turnBackground)
        )
        .overlay(
            isSearchMatch
                ? RoundedRectangle(cornerRadius: 4).stroke(Color.yellow.opacity(0.3), lineWidth: 1)
                : nil
        )
        .contentShape(Rectangle())
    }

    private var isSearchMatch: Bool {
        guard let query = highlightText?.lowercased(), !query.isEmpty else { return false }
        return turn.textPreview.lowercased().contains(query)
            || turn.contentBlocks.contains { $0.text.lowercased().contains(query) }
    }

    private var turnBackground: Color {
        if isHovered && checkpointMode {
            return Color.orange.opacity(0.1)
        }
        if isSearchMatch {
            return Color.yellow.opacity(0.08)
        }
        if turn.role == "user" {
            let textBlocks = turn.contentBlocks.filter { if case .text = $0.kind { true } else { false } }
            if !textBlocks.isEmpty {
                return Color(white: 0.15)
            }
        }
        return .clear
    }

    // MARK: - User turn

    private var userTurnView: some View {
        VStack(alignment: .leading, spacing: 1) {
            let textBlocks = turn.contentBlocks.filter { if case .text = $0.kind { true } else { false } }
            let toolResults = turn.contentBlocks.filter { if case .toolResult = $0.kind { true } else { false } }

            if !textBlocks.isEmpty {
                ForEach(textBlocks.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 0) {
                        if i == 0 {
                            Text("❯ ")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.green)
                                .fontWeight(.bold)
                        } else {
                            Text("  ")
                                .font(.system(.caption, design: .monospaced))
                        }
                        styledText(textBlocks[i].text, color: .white)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } else if !toolResults.isEmpty {
                ForEach(toolResults.indices, id: \.self) { i in
                    toolResultLine(toolResults[i])
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    Text("❯ ")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                        .fontWeight(.bold)
                    styledText(turn.textPreview, color: .white)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Assistant turn

    private var assistantTurnView: some View {
        VStack(alignment: .leading, spacing: 1) {
            if turn.contentBlocks.isEmpty {
                // Fallback for old data without content blocks
                HStack(alignment: .top, spacing: 0) {
                    Text("● ")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white)
                    styledText(turn.textPreview, color: Color(white: 0.85))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(20)
                }
            } else {
                ForEach(turn.contentBlocks.indices, id: \.self) { i in
                    let block = turn.contentBlocks[i]
                    switch block.kind {
                    case .text:
                        textBlockView(block.text, isFirst: i == 0 || !isTextBlock(at: i - 1))
                    case .toolUse(let name, _):
                        toolUseLine(name: name, displayText: block.text)
                    case .toolResult:
                        toolResultLine(block)
                    case .thinking:
                        thinkingLine(block.text)
                    }
                }
            }
        }
    }

    private func isTextBlock(at index: Int) -> Bool {
        guard index >= 0, index < turn.contentBlocks.count else { return false }
        if case .text = turn.contentBlocks[index].kind { return true }
        return false
    }

    // MARK: - Highlighted text helper

    private func styledText(_ text: String, color: Color) -> Text {
        guard let query = highlightText?.lowercased(), !query.isEmpty else {
            return Text(text).foregroundStyle(color)
        }
        var result = AttributedString(text)
        result.foregroundColor = color
        let lowerText = text.lowercased()
        var pos = lowerText.startIndex
        while let range = lowerText.range(of: query, range: pos..<lowerText.endIndex) {
            if let attrStart = AttributedString.Index(range.lowerBound, within: result),
               let attrEnd = AttributedString.Index(range.upperBound, within: result) {
                result[attrStart..<attrEnd].backgroundColor = .yellow.opacity(0.35)
                result[attrStart..<attrEnd].foregroundColor = .yellow
            }
            pos = range.upperBound
        }
        return Text(result)
    }

    // MARK: - Text block

    private func textBlockView(_ text: String, isFirst: Bool) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .top, spacing: 0) {
            if isFirst {
                Text("● ")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
            } else {
                Text("  ")
                    .font(.system(.caption, design: .monospaced))
            }
            styledText(trimmed, color: Color(white: 0.85))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(30)
        }
    }

    // MARK: - Tool use line

    private func toolUseLine(name: String, displayText: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("  ● ")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green)
            Text(name)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green.opacity(0.8))
            if displayText != name {
                let args = displayText.hasPrefix(name) ? String(displayText.dropFirst(name.count)) : "(\(displayText))"
                Text(args)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color(white: 0.5))
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Tool result line

    private func toolResultLine(_ block: ContentBlock) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("  ⎿ ")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color(white: 0.35))
            Text(block.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color(white: 0.35))
                .lineLimit(3)
        }
    }

    // MARK: - Thinking line

    private func thinkingLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("  ∴ ")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color(white: 0.3))
            Text("Thinking...")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color(white: 0.3))
                .italic()
        }
    }

}

// MARK: - Scroll position detector

/// Observes the enclosing NSScrollView to detect whether the user is scrolled to the bottom.
/// When at bottom, auto-scroll is enabled. When the user scrolls up, auto-scroll stops.
/// Scrolling back to bottom re-enables it.
private struct ScrollBottomDetector: NSViewRepresentable {
    @Binding var isAtBottom: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView else { return }
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.boundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isAtBottom: $isAtBottom)
    }

    class Coordinator: NSObject {
        private var isAtBottom: Binding<Bool>

        init(isAtBottom: Binding<Bool>) {
            self.isAtBottom = isAtBottom
        }

        @objc func boundsChanged(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let documentView = clipView.documentView else { return }
            let contentHeight = documentView.frame.height
            let visibleHeight = clipView.bounds.height
            let scrollOffset = clipView.bounds.origin.y
            let threshold: CGFloat = 50
            let atBottom = scrollOffset + visibleHeight >= contentHeight - threshold
            if isAtBottom.wrappedValue != atBottom {
                DispatchQueue.main.async { [isAtBottom] in
                    isAtBottom.wrappedValue = atBottom
                }
            }
        }
    }
}
