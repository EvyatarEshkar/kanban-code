import Testing
import Foundation
@testable import KanbanCore

@Suite("KanbanCard")
struct KanbanCardTests {

    @Test("Display title uses link name first")
    func displayTitleLinkName() {
        let link = Link(name: "Fix login bug", sessionLink: SessionLink(sessionId: "s1"))
        let card = KanbanCard(link: link)
        #expect(card.displayTitle == "Fix login bug")
    }

    @Test("Display title falls back to session")
    func displayTitleSession() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let session = Session(id: "s1", firstPrompt: "Help me debug the auth flow")
        let card = KanbanCard(link: link, session: session)
        #expect(card.displayTitle == "Help me debug the auth flow")
    }

    @Test("Display title falls back to ID prefix")
    func displayTitleFallback() {
        let link = Link(sessionLink: SessionLink(sessionId: "abcdef01-2345-6789-abcd-ef0123456789"))
        let card = KanbanCard(link: link)
        #expect(card.displayTitle == "abcdef01...")
    }

    @Test("Project name extracted from path")
    func projectName() {
        let link = Link(projectPath: "/Users/test/Projects/my-cool-app", sessionLink: SessionLink(sessionId: "s1"))
        let card = KanbanCard(link: link)
        #expect(card.projectName == "my-cool-app")
    }

    @Test("Project name from session when link has none")
    func projectNameFromSession() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let session = Session(id: "s1", projectPath: "/Users/test/Projects/langwatch")
        let card = KanbanCard(link: link, session: session)
        #expect(card.projectName == "langwatch")
    }

    @Test("Relative time formats correctly")
    func relativeTime() {
        #expect(KanbanCard.formatRelativeTime(Date.now) == "just now")
        #expect(KanbanCard.formatRelativeTime(Date.now.addingTimeInterval(-120)) == "2m ago")
        #expect(KanbanCard.formatRelativeTime(Date.now.addingTimeInterval(-7200)) == "2h ago")
        #expect(KanbanCard.formatRelativeTime(Date.now.addingTimeInterval(-86400)) == "yesterday")
        #expect(KanbanCard.formatRelativeTime(Date.now.addingTimeInterval(-259200)) == "3d ago")
    }

    @Test("Column comes from link")
    func column() {
        let link = Link(column: .inReview, sessionLink: SessionLink(sessionId: "s1"))
        let card = KanbanCard(link: link)
        #expect(card.column == .inReview)
    }
}
