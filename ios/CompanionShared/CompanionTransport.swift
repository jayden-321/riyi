import Foundation
import WatchConnectivity
import CryptoKit

/// WC owns background delivery; our outbox owns application-level acknowledgement.
@MainActor final class CompanionTransport: NSObject, WCSessionDelegate {
    var receive: ((CompanionPacket) -> Void)?
    var ready: (() -> Void)?
    var failure: ((String) -> Void)?
    private let session = WCSession.default
    private nonisolated static let pendingLock = NSLock()
    private nonisolated(unsafe) static var pendingCount = 0
    nonisolated static var hasPendingDelivery: Bool { pendingLock.lock(); defer { pendingLock.unlock() }; return pendingCount > 0 }
    nonisolated private static func pending(_ delta: Int) { pendingLock.lock(); defer { pendingLock.unlock() }; pendingCount += delta }
    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self; session.activate()
    }
    func send(_ packet: CompanionPacket, latest: Bool = false) {
        guard session.activationState == .activated else { return }
        #if os(iOS)
        guard session.isPaired, session.isWatchAppInstalled else { return }
        #endif
        do {
            let data = try Wire.data(packet)
            if data.count > 48_000 {
                // Maximum plans exceed WC dictionary budgets. Transfer an immutable file instead.
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard !session.outstandingFileTransfers.contains(where: { $0.file.metadata?["digest"] as? String == digest }) else { return }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("companion-transfer", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(UUID().uuidString + ".json")
                try data.write(to: file, options: .atomic)
                session.transferFile(file, metadata: ["companion": true, "digest": digest]); return
            }
            let value: [String: Any] = ["companion": data]
            if latest { try session.updateApplicationContext(value) }
            else if !session.outstandingUserInfoTransfers.contains(where: { ($0.userInfo["companion"] as? Data) == data }) {
                session.transferUserInfo(value)
            }
            if session.isReachable { session.sendMessage(value, replyHandler: nil, errorHandler: { _ in /* Durable delivery remains queued. */ }) }
        } catch { failure?(error.localizedDescription) }
    }
    nonisolated private func deliver(_ value: [String: Any]) {
        guard let data = value["companion"] as? Data else { return }; deliver(data)
    }
    nonisolated private func deliver(_ data: Data) {
        guard let packet = try? Wire.read(data, as: CompanionPacket.self), packet.protocolVersion == 1 else { return }
        Self.pending(1)
        Task { @MainActor [weak self] in defer { Self.pending(-1) }; self?.receive?(packet) }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [weak self] in
            if let error { self?.failure?(error.localizedDescription) }
            if activationState == .activated { self?.ready?() }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) { Task { @MainActor [weak self] in self?.ready?() } }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { deliver(message) }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) { deliver(userInfo) }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) { deliver(applicationContext) }
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // Read before returning: WatchConnectivity removes its temporary file afterwards.
        guard file.metadata?["companion"] as? Bool == true, let data = try? Data(contentsOf: file.fileURL) else { return }; deliver(data)
    }
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        if let error { Task { @MainActor [weak self] in self?.failure?(error.localizedDescription) } }
    }
    #if os(iOS)
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) { Task { @MainActor [weak self] in self?.ready?() } }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
