import Testing
import Foundation
@testable import KanbanCore

@Suite("PromptBuilder")
struct PromptBuilderTests {

    @Test("Manual task uses promptBody as-is")
    func manualTaskPrompt() {
        let link = Link(
            name: "Fix the bug",
            source: .manual,
            promptBody: "Fix the authentication bug in the login flow"
        )
        let prompt = PromptBuilder.buildPrompt(card: link)
        #expect(prompt == "Fix the authentication bug in the login flow")
    }

    @Test("GitHub issue applies default template")
    func githubIssueDefaultTemplate() {
        let link = Link(
            name: "#42: Fix login",
            source: .githubIssue,
            issueLink: IssueLink(number: 42, body: "The login form crashes")
        )
        let prompt = PromptBuilder.buildPrompt(card: link)
        #expect(prompt.contains("#42:"))
        #expect(prompt.contains("The login form crashes"))
    }

    @Test("GitHub issue with custom template")
    func githubIssueCustomTemplate() {
        let link = Link(
            name: "#42: Fix login",
            source: .githubIssue,
            issueLink: IssueLink(number: 42, body: "Bug report")
        )
        let settings = Settings(githubIssuePromptTemplate: "Issue ${number}: ${body}")
        let prompt = PromptBuilder.buildPrompt(card: link, settings: settings)
        #expect(prompt == "Issue 42: Bug report")
    }

    @Test("Project template overrides global")
    func projectTemplateOverridesGlobal() {
        let link = Link(
            name: "#10: Feature",
            source: .githubIssue,
            issueLink: IssueLink(number: 10, body: "Add dark mode")
        )
        let settings = Settings(githubIssuePromptTemplate: "GLOBAL: ${body}")
        let project = Project(path: "/p", githubIssuePromptTemplate: "PROJECT: ${body}")
        let prompt = PromptBuilder.buildPrompt(card: link, project: project, settings: settings)
        #expect(prompt == "PROJECT: Add dark mode")
    }

    @Test("Prompt template wraps the result")
    func promptTemplateWraps() {
        let link = Link(
            name: "Fix bug",
            source: .manual,
            promptBody: "Fix the bug"
        )
        let settings = Settings(promptTemplate: "You are a senior engineer. ${prompt}")
        let prompt = PromptBuilder.buildPrompt(card: link, settings: settings)
        #expect(prompt == "You are a senior engineer. Fix the bug")
    }

    @Test("Session card uses name as-is")
    func sessionCardUsesName() {
        let link = Link(
            name: "Implement feature X",
            sessionLink: SessionLink(sessionId: "s1")
        )
        let prompt = PromptBuilder.buildPrompt(card: link)
        #expect(prompt == "Implement feature X")
    }

    @Test("Card with no name or body returns empty")
    func emptyCard() {
        let link = Link(source: .discovered)
        let prompt = PromptBuilder.buildPrompt(card: link)
        #expect(prompt.isEmpty)
    }

    @Test("applyTemplate replaces variables")
    func templateVariables() {
        let result = PromptBuilder.applyTemplate(
            "Hello ${name}, you have ${count} items",
            variables: ["name": "Alice", "count": "3"]
        )
        #expect(result == "Hello Alice, you have 3 items")
    }

    @Test("applyTemplate handles missing variables")
    func templateMissingVars() {
        let result = PromptBuilder.applyTemplate(
            "Hello ${name}, ${missing} here",
            variables: ["name": "Bob"]
        )
        #expect(result == "Hello Bob, ${missing} here")
    }
}
