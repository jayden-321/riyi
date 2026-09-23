import XCTest
@testable import AiHealth

final class CoachConversationTests: XCTestCase {
    func testRequestIDCorrelatesNewRunsWithoutBreakingCachedHistory() throws {
        var run = CoachRun(id: newID(), kind: "chat", targetDate: "2026-09-23", timezone: "Asia/Shanghai",
                           status: "running", message: "安排训练", result: nil, model: "test",
                           planId: nil, errorCode: "", notifyAt: nil, createdAt: Date(), completedAt: nil)
        run.requestId = newID()
        XCTAssertEqual(try Wire.read(Wire.data(run), as: CoachRun.self).requestId, run.requestId)
        var old = try JSONSerialization.jsonObject(with: Wire.data(run)) as! [String: Any]
        old.removeValue(forKey: "request_id")
        XCTAssertNil(try Wire.read(JSONSerialization.data(withJSONObject: old), as: CoachRun.self).requestId)
    }

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
