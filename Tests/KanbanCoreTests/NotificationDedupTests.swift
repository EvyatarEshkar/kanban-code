import Testing
import Foundation
@testable import KanbanCore

@Suite("Notification Deduplication")
struct NotificationDedupTests {

    @Test("shouldNotify returns true for first notification")
    func firstNotification() async {
        let dedup = NotificationDeduplicator(dedupWindow: 0.1)
        let should = await dedup.shouldNotify(sessionId: "s1", eventTime: Date())
        #expect(should)
    }

    @Test("Dedup window prevents rapid notifications")
    func dedupWindow() async {
        let dedup = NotificationDeduplicator(dedupWindow: 60)
        let t1 = Date()
        let t2 = t1.addingTimeInterval(10) // 10s later

        let first = await dedup.shouldNotify(sessionId: "s1", eventTime: t1)
        #expect(first)

        // 10s later — within 60s window
        let second = await dedup.shouldNotify(sessionId: "s1", eventTime: t2)
        #expect(!second) // Should be deduped
    }

    @Test("Events outside dedup window both send")
    func outsideWindow() async {
        let dedup = NotificationDeduplicator(dedupWindow: 62)
        let t1 = Date()
        let t2 = t1.addingTimeInterval(63) // 63s later — outside window

        let first = await dedup.shouldNotify(sessionId: "s1", eventTime: t1)
        #expect(first)

        let second = await dedup.shouldNotify(sessionId: "s1", eventTime: t2)
        #expect(second) // Should pass — outside window
    }

    @Test("Different sessions get independent dedup")
    func independentSessions() async {
        let dedup = NotificationDeduplicator(dedupWindow: 60)
        let now = Date()

        let s1 = await dedup.shouldNotify(sessionId: "s1", eventTime: now)
        let s2 = await dedup.shouldNotify(sessionId: "s2", eventTime: now)
        #expect(s1)
        #expect(s2)
    }

    @Test("hasPromptedWithin detects prompt within 1s window")
    func promptWithinWindow() async {
        let dedup = NotificationDeduplicator(dedupWindow: 62)
        let stopTime = Date()
        let promptTime = stopTime.addingTimeInterval(0.5) // 0.5s after stop

        await dedup.recordPrompt(sessionId: "s1", at: promptTime)

        let prompted = await dedup.hasPromptedWithin(sessionId: "s1", after: stopTime)
        #expect(prompted) // Prompt was within 1s of stop
    }

    @Test("hasPromptedWithin ignores prompt outside 1s window")
    func promptOutsideWindow() async {
        let dedup = NotificationDeduplicator(dedupWindow: 62)
        let stopTime = Date()
        let promptTime = stopTime.addingTimeInterval(5) // 5s after stop

        await dedup.recordPrompt(sessionId: "s1", at: promptTime)

        let prompted = await dedup.hasPromptedWithin(sessionId: "s1", after: stopTime)
        #expect(!prompted) // Prompt was 5s after stop, outside 1s window
    }

    @Test("hasPromptedWithin ignores prompt before stop")
    func promptBeforeStop() async {
        let dedup = NotificationDeduplicator(dedupWindow: 62)
        let promptTime = Date()
        let stopTime = promptTime.addingTimeInterval(5) // Stop is 5s after prompt

        await dedup.recordPrompt(sessionId: "s1", at: promptTime)

        let prompted = await dedup.hasPromptedWithin(sessionId: "s1", after: stopTime)
        #expect(!prompted) // Prompt was before the stop
    }

    @Test("Batch processing scenario: multiple stops with prompts in between")
    func batchProcessing() async {
        // Simulates the exact scenario from hook-events.jsonl:
        // UPS@T+0, Stop@T+4, UPS@T+8, Stop@T+10, UPS@T+66, Stop@T+68
        let dedup = NotificationDeduplicator(dedupWindow: 62)
        let base = Date(timeIntervalSinceReferenceDate: 0)

        // Events processed in a batch (all at once):
        await dedup.recordPrompt(sessionId: "s1", at: base.addingTimeInterval(0))   // UPS@T+0
        // Stop@T+4 will be checked below
        await dedup.recordPrompt(sessionId: "s1", at: base.addingTimeInterval(8))   // UPS@T+8
        // Stop@T+10 will be checked below
        await dedup.recordPrompt(sessionId: "s1", at: base.addingTimeInterval(66))  // UPS@T+66
        // Stop@T+68 will be checked below

        // Stop@T+4: prompt at T+8 is 4s after → outside 1s window → NOT blocked
        let stop1Prompted = await dedup.hasPromptedWithin(sessionId: "s1", after: base.addingTimeInterval(4))
        #expect(!stop1Prompted)
        let stop1Send = await dedup.shouldNotify(sessionId: "s1", eventTime: base.addingTimeInterval(4))
        #expect(stop1Send) // First notification sends

        // Stop@T+10: prompt at T+66 is 56s after → outside 1s window → NOT blocked
        let stop2Prompted = await dedup.hasPromptedWithin(sessionId: "s1", after: base.addingTimeInterval(10))
        #expect(!stop2Prompted)
        let stop2Send = await dedup.shouldNotify(sessionId: "s1", eventTime: base.addingTimeInterval(10))
        #expect(!stop2Send) // DEDUPED: only 6s since Stop@T+4

        // Stop@T+68: no prompt after T+68 → NOT blocked
        let stop3Prompted = await dedup.hasPromptedWithin(sessionId: "s1", after: base.addingTimeInterval(68))
        #expect(!stop3Prompted)
        let stop3Send = await dedup.shouldNotify(sessionId: "s1", eventTime: base.addingTimeInterval(68))
        #expect(stop3Send) // Sends: 64s since Stop@T+4, outside 62s window
    }
}
