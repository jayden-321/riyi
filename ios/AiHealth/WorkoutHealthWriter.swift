import Foundation
import HealthKit
import WatchConnectivity

@MainActor final class WorkoutHealthWriter {
    private let health = HKHealthStore()
    private var writing = Set<String>()
    var hasPairedWatch: Bool { WCSession.isSupported() && WCSession.default.isPaired && WCSession.default.isWatchAppInstalled }

    /// Watch owns its own HKWorkout. The phone writes only for phone-only sessions automatically;
    /// a completed session can also be exported explicitly after checking HealthKit for its ID.
    func write(_ workout: Workout, automatic: Bool) async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable(), let end = workout.finishedAt,
              workout.status == "completed", end > workout.startedAt else { return false }
        if automatic && hasPairedWatch { return false }
        guard writing.insert(workout.id).inserted else { return false }
        defer { writing.remove(workout.id) }

        let type = HKObjectType.workoutType()
        let distanceType: HKQuantityType? = switch workout.activity?.resolvedSport {
        case "swimming": HKQuantityType(.distanceSwimming)
        case "cycling": HKQuantityType(.distanceCycling)
        case "walking", "running", "hiking": HKQuantityType(.distanceWalkingRunning)
        default: nil
        }
        var writable: Set<HKSampleType> = [type]
        if workout.actualDistanceMeters != nil, let distanceType { writable.insert(distanceType) }
        try await health.requestAuthorization(toShare: writable, read: [type])
        guard health.authorizationStatus(for: type) == .sharingAuthorized else {
            throw NSError(domain: "RiyiHealth", code: 1, userInfo: [NSLocalizedDescriptionKey: "请在系统健康权限中允许日益写入训练"])
        }
        if workout.actualDistanceMeters != nil, let distanceType,
           health.authorizationStatus(for: distanceType) != .sharingAuthorized {
            throw NSError(domain: "RiyiHealth", code: 3, userInfo: [NSLocalizedDescriptionKey: "请在系统健康权限中允许写入本次运动距离"])
        }
        if try await exists(workout.id) { return true }

        let configuration = healthWorkoutConfiguration(for: workout)
        let builder = HKWorkoutBuilder(healthStore: health, configuration: configuration, device: .local())
        try await builder.beginCollection(at: workout.startedAt)
        do {
            var metadata: [String: Any] = [HKMetadataKeyExternalUUID: workout.id, "riyi_session_id": workout.id]
            if workout.activity?.resolvedSport == "swimming" {
                let location: HKWorkoutSwimmingLocationType = workout.activity?.swimLocation == "pool" ? .pool : .openWater
                metadata[HKMetadataKeySwimmingLocationType] = NSNumber(value: location.rawValue)
                if let length = workout.activity?.poolLengthMeters { metadata[HKMetadataKeyLapLength] = HKQuantity(unit: .meter(), doubleValue: length) }
            }
            try await builder.addMetadata(metadata)
            if let distance = workout.actualDistanceMeters, distance > 0, let distanceType {
                let sample = HKQuantitySample(type: distanceType, quantity: HKQuantity(unit: .meter(), doubleValue: distance), start: workout.startedAt, end: end)
                try await builder.addSamples([sample])
            }
            try await builder.endCollection(at: end)
            guard try await builder.finishWorkout() != nil else {
                throw NSError(domain: "RiyiHealth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple 健康没有确认保存训练"])
            }
            return true
        } catch {
            builder.discardWorkout()
            throw error
        }
    }

    private func exists(_ id: String) async throws -> Bool {
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [id])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: !(samples ?? []).isEmpty) }
            }
            health.execute(query)
        }
    }
}
