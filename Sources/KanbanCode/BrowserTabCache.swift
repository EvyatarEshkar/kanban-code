import Foundation
import WebKit

/// Holds live `BrowserTab` (WKWebView) instances across card switches.
/// Keyed by `(cardId, tabId)` so each card has its own independent set.
/// Analogous to `TerminalCache` for terminal views.
@MainActor
final class BrowserTabCache {
    static let shared = BrowserTabCache()

    /// cardId → [tabId: BrowserTab], preserving insertion order via array
    private var tabs: [String: [(id: String, tab: BrowserTab)]] = [:]

    private init() {}

    /// Returns an existing `BrowserTab` or creates a new one navigating to `url`.
    func getOrCreate(cardId: String, tabId: String, url: URL) -> BrowserTab {
        if let entry = tabs[cardId]?.first(where: { $0.id == tabId }) {
            return entry.tab
        }
        let tab = BrowserTab(id: tabId, url: url)
        tabs[cardId, default: []].append((id: tabId, tab: tab))
        return tab
    }

    /// All live browser tabs for a card, in insertion order.
    func tabsForCard(_ cardId: String) -> [BrowserTab] {
        tabs[cardId]?.map(\.tab) ?? []
    }

    /// Remove a single tab (e.g. user closed it).
    func remove(cardId: String, tabId: String) {
        tabs[cardId]?.removeAll { $0.id == tabId }
        if tabs[cardId]?.isEmpty == true { tabs[cardId] = nil }
    }

    /// Remove all tabs for a card (e.g. card deleted/archived).
    func removeAllForCard(_ cardId: String) {
        tabs[cardId] = nil
    }
}
