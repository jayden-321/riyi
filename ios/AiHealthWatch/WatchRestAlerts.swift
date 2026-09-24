import Foundation
import UserNotifications

@MainActor final class WatchRestAlerts {
    private let center = UNUserNotificationCenter.current()
    private var scheduledID: String?
    private var scheduledAt: Date?
    private var askedAuthorization = false
    var onPermissionStatus: ((Bool) -> Void)?

    func prepareAuthorization(for workout: Workout?) {
        guard workout?.status == "in_progress", workout?.synthetic != true, !askedAuthorization else { return }
        askedAuthorization = true
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let latest = await center.notificationSettings()
            onPermissionStatus?(latest.authorizationStatus == .authorized || latest.authorizationStatus == .provisional)
        }
    }

    func reconcile(workout: Workout?) {
        guard let workout, workout.status == "in_progress", workout.synthetic != true,
              let restUntil = workout.restUntil, restUntil > Date().addingTimeInterval(1) else {
            cancel(); return
        }
        let id = "riyi-rest-" + workout.id
        guard scheduledID != id || scheduledAt != restUntil else { return }
        cancel()
        scheduledID = id; scheduledAt = restUntil
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let permitted = await center.notificationSettings()
            guard permitted.authorizationStatus == .authorized || permitted.authorizationStatus == .provisional,
                  scheduledID == id, scheduledAt == restUntil else { return }
            let content = UNMutableNotificationContent()
            content.title = "休息结束"
            content.body = "可以开始下一组了"
            content.sound = .default
            let seconds = max(1, restUntil.timeIntervalSinceNow)
            let request = UNNotificationRequest(identifier: id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))
            try? await center.add(request)
        }
    }

    private func cancel() {
        if let scheduledID { center.removePendingNotificationRequests(withIdentifiers: [scheduledID]) }
        scheduledID = nil; scheduledAt = nil
    }
}
