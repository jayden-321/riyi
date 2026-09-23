import Foundation
import UserNotifications
import CryptoKit

struct ReminderSettings: Codable { var start = 8; var end = 22; var interval = 2; var enabled = false }

@MainActor final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifications()
    weak var store: AppStore?
    func configure(store: AppStore) {
        self.store = store
        let center = UNUserNotificationCenter.current(); center.delegate = self
        let actions = [UNNotificationAction(identifier: "water250", title: "250 ml"), UNNotificationAction(identifier: "water500", title: "500 ml"), UNNotificationAction(identifier: "snooze", title: "稍后提醒")]
        center.setNotificationCategories([UNNotificationCategory(identifier: "water", actions: actions, intentIdentifiers: [], options: [])])
    }
    func schedule(start: Int, end: Int, interval: Int) async throws {
        guard let store, store.signedIn, (0...23).contains(start), (0...23).contains(end), start < end, interval > 0 else { throw AppError.message("请设置有效的提醒时段") }
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw AppError.message("通知未获允许，可以在系统设置中开启") }
        await cancelWater()
        for hour in stride(from: start, through: end, by: interval) {
            let content = UNMutableNotificationContent(); content.title = "该喝水了 💧"; content.body = "按需要补水，记录刚刚喝下的量。"
            content.categoryIdentifier = "water"; content.sound = .default; content.userInfo = ["scope": store.scope]
            let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: 0), repeats: true)
            try await center.add(UNNotificationRequest(identifier: "water.\(hour)", content: content, trigger: trigger))
        }
        UserDefaults.standard.set(try Wire.data(ReminderSettings(start: start, end: end, interval: interval, enabled: true)), forKey: "reminders.\(store.scope)")
    }
    func savedSettings() -> ReminderSettings {
        guard let store, let data = UserDefaults.standard.data(forKey: "reminders.\(store.scope)"), let settings: ReminderSettings = try? Wire.read(data) else { return ReminderSettings() }; return settings
    }
    func cancel() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests(); UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        if let store { UserDefaults.standard.set(false, forKey: "coachReminders.\(store.scope)") }
        if let store { var settings = savedSettings(); settings.enabled = false; if let data = try? Wire.data(settings) { UserDefaults.standard.set(data, forKey: "reminders.\(store.scope)") } }
    }
    func cancelCoach() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["coach.fitness", "coach.sleep"])
        if let store { UserDefaults.standard.set(false, forKey: "coachReminders.\(store.scope)") }
    }
    func cancelWater() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("water.") }.map(\.identifier))
        if let store { var settings = savedSettings(); settings.enabled = false; if let data = try? Wire.data(settings) { UserDefaults.standard.set(data, forKey: "reminders.\(store.scope)") } }
    }
    func scheduleCoach(_ settings: CoachSettings, enabled: Bool) async throws {
        guard let store else { return }
        let center = UNUserNotificationCenter.current(), owner = store.scope
        center.removePendingNotificationRequests(withIdentifiers: ["coach.fitness", "coach.sleep"])
        UserDefaults.standard.set(false, forKey: "coachReminders.\(owner)")
        guard enabled else { return }
        guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw AppError.message("系统未允许通知") }
        guard store.scope == owner else { return }
        let zone = TimeZone(identifier: store.settings.timezone) ?? .current
        for (kind, active, minute, title, body) in [
            ("fitness", settings.fitnessEnabled, settings.fitnessReminderMinute, "看看今天怎么练", "打开日益，查看服务器的训练安排与分析。"),
            ("sleep", settings.sleepEnabled, settings.sleepReminderMinute, "准备今晚的好睡眠", "打开日益，看看今晚的睡眠建议。")
        ] where active {
            let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
            content.userInfo = ["scope": owner, "coach": true]
            let components = DateComponents(timeZone: zone, hour: minute / 60, minute: minute % 60)
            try await center.add(UNNotificationRequest(identifier: "coach.\(kind)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)))
        }
        UserDefaults.standard.set(true, forKey: "coachReminders.\(owner)")
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await handle(response)
    }
    private func handle(_ response: UNNotificationResponse) async {
        guard let store, let scope = response.notification.request.content.userInfo["scope"] as? String, scope == store.scope else { return }
        if response.notification.request.content.userInfo["coach"] as? Bool == true { store.selectedTab = "coach"; await store.loadCoach(); return }
        if response.actionIdentifier == "snooze" {
            let content = response.notification.request.content.mutableCopy() as! UNMutableNotificationContent
            do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "water.snooze.\(newID())", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 15 * 60, repeats: false))) }
            catch { store.error = error.localizedDescription }; return
        }
        let amount = response.actionIdentifier == "water250" ? 250 : response.actionIdentifier == "water500" ? 500 : 0
        guard amount > 0 else { return }
        // Stable per delivered notification; a repeated action callback cannot double-log water.
        let input = "\(scope)/\(response.notification.request.identifier)/\(response.notification.date.timeIntervalSince1970)"
        let digest = Array(SHA256.hash(data: Data(input.utf8))); let u = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let id = "\(u.prefix(8))-\(u.dropFirst(8).prefix(4))-\(u.dropFirst(12).prefix(4))-\(u.dropFirst(16).prefix(4))-\(u.suffix(12))"
        store.addWater(amount, source: "notification", id: id)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
