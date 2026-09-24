import SwiftUI
import WatchKit
import HealthKit

private struct WatchNativeActivityRings: WKInterfaceObjectRepresentable {
    let summary: HKActivitySummary
    func makeWKInterfaceObject(context: Context) -> WKInterfaceActivityRing { WKInterfaceActivityRing() }
    func updateWKInterfaceObject(_ ring: WKInterfaceActivityRing, context: Context) {
        ring.setActivitySummary(summary, animated: false)
    }
}

enum WatchActivitySummaryReader {
    static func today() async throws -> HKActivitySummary? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--watch-rings-demo") {
            let summary = HKActivitySummary()
            summary.activityMoveMode = .activeEnergy
            summary.activeEnergyBurned = HKQuantity(unit: .kilocalorie(), doubleValue: 284)
            summary.activeEnergyBurnedGoal = HKQuantity(unit: .kilocalorie(), doubleValue: 1500)
            summary.appleExerciseTime = HKQuantity(unit: .minute(), doubleValue: 11)
            summary.appleExerciseTimeGoal = HKQuantity(unit: .minute(), doubleValue: 30)
            summary.appleStandHours = HKQuantity(unit: .count(), doubleValue: 10)
            summary.appleStandHoursGoal = HKQuantity(unit: .count(), doubleValue: 12)
            return summary
        }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let health = HKHealthStore(), type = HKObjectType.activitySummaryType()
        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKAuthorizationRequestStatus, Error>) in
            health.getRequestStatusForAuthorization(toShare: [], read: [type]) { status, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: status) }
            }
        }
        if status == .shouldRequest { try await health.requestAuthorization(toShare: [], read: [type]) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        var today = calendar.dateComponents([.year, .month, .day], from: Date())
        today.calendar = calendar
        let tomorrowDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        var tomorrow = calendar.dateComponents([.year, .month, .day], from: tomorrowDate)
        tomorrow.calendar = calendar
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: today, end: tomorrow)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKActivitySummary?, Error>) in
            let query = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: summaries?.first(where: {
                    let day = $0.dateComponents(for: calendar)
                    return day.year == today.year && day.month == today.month && day.day == today.day
                })) }
            }
            health.execute(query)
        }
    }
}

struct WatchIdleActivityRings: View {
    let now: Date
    let refreshRevision: Int
    @State private var summary: HKActivitySummary?
    @State private var loading = true
    var body: some View {
        Group {
            if let summary {
                HStack(spacing: 3) {
                    WatchNativeActivityRings(summary: summary)
                        .frame(width: 79, height: 79).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("活动 \(Int(summary.activeEnergyBurned.doubleValue(for: .kilocalorie())))").foregroundStyle(.red)
                        Text("锻炼 \(Int(summary.appleExerciseTime.doubleValue(for: .minute())))分").foregroundStyle(.green)
                        Text("站立 \(Int(summary.appleStandHours.doubleValue(for: .count())))时").foregroundStyle(.cyan)
                    }.font(.system(size: 10, weight: .semibold)).minimumScaleFactor(0.7)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 79) }
            else { Text("活动圆环暂无数据").font(.caption2).foregroundStyle(.secondary).frame(height: 79) }
        }.accessibilityIdentifier("watch-idle-activity-rings")
            .task(id: String(Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)) + "/" + String(refreshRevision)) {
                loading = true
                summary = try? await WatchActivitySummaryReader.today()
                loading = false
            }
    }
}
