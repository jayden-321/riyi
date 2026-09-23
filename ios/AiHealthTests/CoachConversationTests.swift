import XCTest
@testable import AiHealth

final class CoachConversationTests: XCTestCase {
    func testClearingConversationKeepsScheduledAnalysisOutOfChat() {
        let now = Date()
        let chat = CoachRun(id: newID(), kind: "chat", targetDate: "2026-09-23", timezone: "Asia/Shanghai",
                            status: "completed", message: "继续讨论训练", result: nil, model: "test",
                            planId: nil, errorCode: "", notifyAt: nil, createdAt: now, completedAt: now)
        var sleep = chat; sleep.id = newID(); sleep.kind = "sleep"; sleep.message = "今晚作息分析"
        var fitness = chat; fitness.id = newID(); fitness.kind = "fitness"; fitness.message = "次日训练分析"
        var state = CoachState(runs: [chat, sleep, fitness])
        XCTAssertEqual(state.conversationRuns.map(\.id), [chat.id])
        XCTAssertEqual(state.analysisRuns.count, 2)
        state.runs.removeAll { $0.kind == "chat" }
        XCTAssertTrue(state.conversationRuns.isEmpty)
        XCTAssertEqual(Set(state.analysisRuns.map(\.id)), Set([sleep.id, fitness.id]))
    }
}
