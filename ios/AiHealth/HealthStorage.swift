import Foundation
import SwiftData

struct HealthUploadBatch: Sendable { let id: String; let payload: Data; let count: Int }
struct HealthUploadProgress: Sendable { let uploaded: Int; let target: Int; let pendingBatches: Int; let finished: Bool }
struct HealthOverviewSnapshot: Codable { let count: Int; let latest: [HealthSample]; var summary: DailySummary }
struct LocalOverviewCache: Codable {
    let algorithm: Int
    let timezone: String
    let date: String
    let since: Date
    var water: Int
    var snapshot: HealthOverviewSnapshot
    init(timezone: String, date: String, since: Date, water: Int, snapshot: HealthOverviewSnapshot) {
        algorithm = 1; self.timezone = timezone; self.date = date; self.since = since; self.water = water; self.snapshot = snapshot
    }
}
struct SleepDayCache: Codable {
    let algorithm: Int
    let date: String
    let timezone: String
    let night: SleepNight?
    let cachedAt: Date
    let cachedAtMilliseconds: Int64
    init(date: String, timezone: String, night: SleepNight?, cachedAt: Date = Date()) {
        self.algorithm = 2; self.date = date; self.timezone = timezone; self.night = night; self.cachedAt = cachedAt
        self.cachedAtMilliseconds = Int64(cachedAt.timeIntervalSince1970 * 1000)
    }
}

private final class HealthExecutor: SerialExecutor, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.aijiankang.health-storage", qos: .utility)
    func enqueue(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

/// A dedicated serial executor guarantees that SQLite / JSON work never runs on the UI thread.
actor HealthStorage {
    private nonisolated let executor = HealthExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    let modelContainer: ModelContainer
    private var storedContext: ModelContext?
    private(set) var sleepRawScanCount = 0
    private(set) var overviewRawScanCount = 0
    var modelContext: ModelContext {
        if let storedContext { return storedContext }
        let context = ModelContext(modelContainer); context.autosaveEnabled = false; storedContext = context; return context
    }
    init(modelContainer: ModelContainer) { self.modelContainer = modelContainer }
    static let batchSize = 500
    private func checkpoint(_ scope: String) throws -> HealthUploadCheckpoint {
        var q = FetchDescriptor<HealthUploadCheckpoint>(predicate: #Predicate { $0.scope == scope }); q.fetchLimit = 1
        if let value = try modelContext.fetch(q).first { return value }
        let value = HealthUploadCheckpoint(scope: scope); modelContext.insert(value); return value
    }
    private func batchData(_ payloads: [Data]) -> Data {
        var data = Data("{\"samples\":[".utf8)
        for (index, payload) in payloads.enumerated() { if index > 0 { data.append(44) }; data.append(payload) }
        data.append(contentsOf: Data("]}".utf8)); return data
    }
    func progress(scope: String) throws -> HealthUploadProgress {
        let state = try checkpoint(scope)
        let count = try modelContext.fetchCount(FetchDescriptor<PendingChange>(predicate: #Predicate { $0.scope == scope && $0.kind == "health" }))
        return HealthUploadProgress(uploaded: state.uploaded, target: state.target, pendingBatches: count, finished: state.finished)
    }
    func startBackfill(scope: String, restart: Bool, since: Date) throws -> HealthUploadProgress {
        let state = try checkpoint(scope)
        let verifiedKey = "healthBackfillVerifiedV14.\(scope)"
        if restart { state.cursor = ""; state.finished = false; state.uploaded = 0; UserDefaults.standard.removeObject(forKey: verifiedKey) }
        if state.finished && UserDefaults.standard.bool(forKey: verifiedKey) {
            // Every later HealthKit change with cloud consent is queued in persist() in the same transaction.
            // A completed checkpoint therefore does not need another count over hundreds of thousands of rows.
            return try progress(scope: scope)
        }
        let remaining = try modelContext.fetchCount(FetchDescriptor<LocalHealthRecord>(predicate: #Predicate { $0.scope == scope && !$0.cloudUploaded && ($0.tombstoned || ($0.endAt != nil && $0.endAt! >= since)) }))
        if state.finished && remaining > 0 { state.cursor = ""; state.finished = false; state.uploaded = 0 }
        if !state.finished { state.target = state.uploaded + remaining }
        if state.finished && remaining == 0 { UserDefaults.standard.set(true, forKey: verifiedKey) }
        try modelContext.save(); return try progress(scope: scope)
    }
    /// Prepares one batch only. Cursor and outbox are committed atomically.
    func prepareNextBatch(scope: String, since: Date) throws -> HealthUploadProgress {
        let state = try checkpoint(scope)
        guard !state.finished else { return try progress(scope: scope) }
        let after = state.cursor
        var q = FetchDescriptor<LocalHealthRecord>(predicate: #Predicate { $0.scope == scope && !$0.cloudUploaded && $0.key > after && ($0.tombstoned || ($0.endAt != nil && $0.endAt! >= since)) }, sortBy: [SortDescriptor(\.key, comparator: .lexical)])
        q.fetchLimit = Self.batchSize
        let rows = try modelContext.fetch(q)
        if rows.isEmpty {
            let remaining = try modelContext.fetchCount(FetchDescriptor<LocalHealthRecord>(predicate: #Predicate { $0.scope == scope && !$0.cloudUploaded && ($0.tombstoned || ($0.endAt != nil && $0.endAt! >= since)) }))
            // Also catches newly inserted records whose keys precede the cursor.
            if remaining > 0 && !state.cursor.isEmpty { state.cursor = ""; return try prepareNextBatch(scope: scope, since: since) }
            if remaining > 0 { throw AppError.message("仍有待上传记录，无法推进断点，请稍后重试") }
            state.finished = true
        }
        else {
            modelContext.insert(PendingChange(scope: scope, kind: "health", recordId: newID(), payload: batchData(rows.map(\.payload))))
            state.cursor = rows.last!.key
        }
        try modelContext.save(); return try progress(scope: scope)
    }
    /// v3 queues can also be drained without loading their other batches into memory.
    func nextUpload(scope: String, since: Date) throws -> HealthUploadBatch? {
        var q = FetchDescriptor<PendingChange>(predicate: #Predicate { $0.scope == scope && $0.kind == "health" }, sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)])
        q.fetchLimit = 1
        guard let row = try modelContext.fetch(q).first else { return nil }
        let payload: [String: [HealthSample]] = try Wire.read(row.payload)
        let eligible = (payload["samples"] ?? []).filter { $0.deleted || ($0.endAt != nil && $0.endAt! >= since) }
        return HealthUploadBatch(id: row.id, payload: try Wire.data(["samples": eligible]), count: eligible.count)
    }
    func acknowledge(scope: String, batch: HealthUploadBatch) throws -> HealthUploadProgress {
        let id = batch.id
        var q = FetchDescriptor<PendingChange>(predicate: #Predicate { $0.scope == scope && $0.id == id && $0.kind == "health" }); q.fetchLimit = 1
        guard let queued = try modelContext.fetch(q).first else { return try progress(scope: scope) }
        let payload: [String: [HealthSample]] = try Wire.read(batch.payload)
        let samples = payload["samples"] ?? [], keys = samples.map { scope + "/" + $0.healthkitUuid }
        let rows = try modelContext.fetch(FetchDescriptor<LocalHealthRecord>(predicate: #Predicate { keys.contains($0.key) }))
        let deletedIDs = Set(samples.filter(\.deleted).map(\.healthkitUuid))
        let byID = try samples.reduce(into: [String: Data]()) { result, sample in
            if sample.deleted || !deletedIDs.contains(sample.healthkitUuid) { result[sample.healthkitUuid] = try Wire.data(sample) }
        }
        for row in rows {
            // Preserve the main task's repair of legacy deletion flags lost by SwiftData.
            guard let recorded: HealthSample = try? Wire.read(row.payload) else { continue }
            if deletedIDs.contains(row.sampleId) && !row.tombstoned && recorded.deleted { row.tombstoned = true }
            // Canonicalize old second-resolution payloads before comparing new millisecond wire data.
            // An older ACK must never hide newer Watch metadata.
            if byID[row.sampleId] == (try? Wire.data(recorded)) { row.cloudUploaded = true }
        }
        modelContext.delete(queued)
        let state = try checkpoint(scope); state.uploaded += batch.count
        try modelContext.save(); return try progress(scope: scope)
    }
    @discardableResult func persist(samples: [HealthSample], anchor: Data?, cursorKey: String, scope: String, upload: Bool) throws -> Bool {
        modelContext.autosaveEnabled = false
        let encoder = Wire.encoder()
        let encoded = try samples.map { ($0, try encoder.encode($0)) }, keys = samples.map { scope + "/" + $0.healthkitUuid }
        let existing = try modelContext.fetch(FetchDescriptor<LocalHealthRecord>(predicate: #Predicate { keys.contains($0.key) }))
        var byKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })
        var cq = FetchDescriptor<HealthCursor>(predicate: #Predicate { $0.key == cursorKey }); cq.fetchLimit = 1
        let cursor = try modelContext.fetch(cq).first ?? HealthCursor(key: cursorKey)
        if cursor.modelContext == nil { modelContext.insert(cursor) }
        var changed: [Data] = []
        var sleepIntervals: [(Date, Date)] = []
        for (sample, data) in encoded {
            let previousCount = changed.count
            let key = scope + "/" + sample.healthkitUuid
            let previous = byKey[key]
            if let row = byKey[key] {
                if sample.deleted && !row.tombstoned { row.tombstoned = true; row.payload = data; row.cloudUploaded = false; changed.append(data) }
                else if !row.tombstoned && !sample.deleted, var original: HealthSample = try? Wire.read(row.payload) {
                    // Preserve the UUID's immutable observation. Add missing Watch context/series
                    // even when iPhone HealthKit sync delivered this UUID first.
                    var enriched = false
                    for (key, value) in sample.metadataJson where original.metadataJson[key] == nil {
                        original.metadataJson[key] = value; enriched = true
                    }
                    if enriched { let merged = try encoder.encode(original); row.payload = merged; row.cloudUploaded = false; changed.append(merged) }
                }
            } else { let row = LocalHealthRecord(scope: scope, sample: sample, payload: data); modelContext.insert(row); byKey[key] = row; changed.append(data) }
            if sample.type == "sleep_analysis", changed.count > previousCount, let start = sample.startAt ?? previous?.startAt, let end = sample.endAt ?? previous?.endAt {
                sleepIntervals.append((start, end))
            }
        }
        if !sleepIntervals.isEmpty { try invalidateSleepCache(scope: scope, intervals: sleepIntervals) }
        if !changed.isEmpty { try invalidateOverviewCache(scope: scope) }
        if upload {
            for i in stride(from: 0, to: changed.count, by: Self.batchSize) {
                modelContext.insert(PendingChange(scope: scope, kind: "health", recordId: newID(), payload: batchData(Array(changed[i..<min(i + Self.batchSize, changed.count)]))))
            }
        }
        if !upload && !changed.isEmpty { UserDefaults.standard.removeObject(forKey: "healthBackfillVerifiedV14.\(scope)") }
        cursor.anchor = anchor; cursor.updatedAt = Date()
        do { try modelContext.save() } catch { modelContext.rollback(); throw error }
        return !changed.isEmpty
    }
    func anchor(key: String) throws -> Data? {
        var q = FetchDescriptor<HealthCursor>(predicate: #Predicate { $0.key == key }); q.fetchLimit = 1
        return try modelContext.fetch(q).first?.anchor
    }
    func resetAnchors(scope: String) throws {
        let prefix = scope + "/"
        for cursor in try modelContext.fetch(FetchDescriptor<HealthCursor>(predicate: #Predicate { $0.key.starts(with: prefix) })) { cursor.anchor = nil }
        try modelContext.save()
    }
    func resetAnchor(key: String) throws {
        var query = FetchDescriptor<HealthCursor>(predicate: #Predicate { $0.key == key }); query.fetchLimit = 1
        if let cursor = try modelContext.fetch(query).first { cursor.anchor = nil; try modelContext.save() }
    }
    func remove(scope: String) throws {
        try modelContext.delete(model: LocalHealthRecord.self, where: #Predicate { $0.scope == scope })
        try modelContext.delete(model: PendingChange.self, where: #Predicate { $0.scope == scope && $0.kind == "health" })
        try modelContext.delete(model: HealthUploadCheckpoint.self, where: #Predicate { $0.scope == scope })
        UserDefaults.standard.removeObject(forKey: "healthBackfillVerifiedV14.\(scope)")
        try modelContext.delete(model: LocalRecord.self, where: #Predicate { $0.scope == scope && ($0.kind == "sleep_cache" || $0.kind == "sleep_cloud_cache") })
        try modelContext.delete(model: LocalRecord.self, where: #Predicate { $0.scope == scope && $0.kind == "health_overview_cache" })
        let prefix = scope + "/"
        try modelContext.delete(model: HealthCursor.self, where: #Predicate { $0.key.starts(with: prefix) })
        try modelContext.save()
    }
    private func sleepCacheKey(scope: String, kind: String, zone: String, day: String) -> String {
        scope + "/" + kind + "/" + stableID(zone + "/" + day)
    }
    private func invalidateOverviewCache(scope: String) throws {
        for row in try modelContext.fetch(FetchDescriptor<LocalRecord>(predicate: #Predicate { $0.scope == scope && $0.kind == "health_overview_cache" })) { modelContext.delete(row) }
    }
    private func cache(scope: String, kind: String, zone: String, day: String) throws -> SleepDayCache? {
        let key = sleepCacheKey(scope: scope, kind: kind, zone: zone, day: day)
        var request = FetchDescriptor<LocalRecord>(predicate: #Predicate { $0.key == key }); request.fetchLimit = 1
        guard let record = try modelContext.fetch(request).first, !record.tombstoned,
              let entry: SleepDayCache = try? Wire.read(record.payload), entry.algorithm == 2,
              entry.timezone == zone, entry.date == day else { return nil }
        return entry
    }
    private func saveCache(scope: String, kind: String, entry: SleepDayCache) throws {
        let id = stableID(entry.timezone + "/" + entry.date)
        let key = sleepCacheKey(scope: scope, kind: kind, zone: entry.timezone, day: entry.date)
        var request = FetchDescriptor<LocalRecord>(predicate: #Predicate { $0.key == key }); request.fetchLimit = 1
        let record = try modelContext.fetch(request).first ?? LocalRecord(scope: scope, kind: kind, id: id, payload: Data())
        if record.modelContext == nil { modelContext.insert(record) }
        record.payload = try Wire.data(entry); record.tombstoned = false; record.updatedAt = entry.cachedAt
    }
    private func invalidateSleepCache(scope: String, intervals: [(Date, Date)]? = nil) throws {
        let rows = try modelContext.fetch(FetchDescriptor<LocalRecord>(predicate: #Predicate { $0.scope == scope && ($0.kind == "sleep_cache" || $0.kind == "sleep_cloud_cache") }))
        for row in rows {
            guard let intervals else { modelContext.delete(row); continue }
            guard let entry: SleepDayCache = try? Wire.read(row.payload), let day = DayKey.date(entry.date, zone: entry.timezone) else { modelContext.delete(row); continue }
            let calendar = DayKey.calendar(entry.timezone)
            let lower = calendar.date(byAdding: .day, value: -2, to: day)!
            let upper = calendar.date(byAdding: .day, value: 3, to: day)!
            if intervals.contains(where: { $0.1 >= lower && $0.0 < upper }) { modelContext.delete(row) }
        }
    }
    func clearSleepCache(scope: String) throws {
        try invalidateSleepCache(scope: scope)
        try modelContext.save()
    }
    func clearSleepCache(scope: String, zone: String, date: String) throws {
        let keys = ["sleep_cache", "sleep_cloud_cache"].map { sleepCacheKey(scope: scope, kind: $0, zone: zone, day: date) }
        for row in try modelContext.fetch(FetchDescriptor<LocalRecord>(predicate: #Predicate { keys.contains($0.key) })) { modelContext.delete(row) }
        try modelContext.save()
    }
    func cachedCloudNight(scope: String, zone: String, date: String, lastSync: Date?, now: Date) throws -> (Bool, SleepNight?) {
        guard let value = try cache(scope: scope, kind: "sleep_cloud_cache", zone: zone, day: date),
              value.cachedAt <= now, (lastSync == nil || Int64(lastSync!.timeIntervalSince1970 * 1000) <= value.cachedAtMilliseconds),
              now.timeIntervalSince(value.cachedAt) < (value.night == nil ? 900 : 21600) else { return (false, nil) }
        return (true, value.night)
    }
    func saveCloudNight(scope: String, zone: String, date: String, night: SleepNight?) throws {
        try saveCache(scope: scope, kind: "sleep_cloud_cache", entry: SleepDayCache(date: date, timezone: zone, night: night))
        try modelContext.save()
    }
    /// Cached daily aggregates avoid rereading the raw sleep rows when a date is opened again.
    func sleepHistory(scope: String, zone: String, days: [Date], since: Date, now: Date) throws -> [SleepNight] {
        let calendar = DayKey.calendar(zone)
        let visible = days.filter { $0 >= calendar.startOfDay(for: since) && $0 <= now }
        guard let first = visible.min(), let last = visible.max() else { return [] }
        var found: [String: SleepNight] = [:], missing: [Date] = []
        for day in visible {
            let key = DayKey.string(day, zone: zone)
            if let stored = try cache(scope: scope, kind: "sleep_cache", zone: zone, day: key) {
                if let night = stored.night { found[key] = night }
            } else { missing.append(day) }
        }
        if !missing.isEmpty {
            sleepRawScanCount += 1
            let from = max(since, calendar.date(byAdding: .day, value: -2, to: missing.min() ?? first)!)
            let until = min(now, calendar.date(byAdding: .day, value: 3, to: missing.max() ?? last)!)
            let query = FetchDescriptor<LocalHealthRecord>(predicate: #Predicate {
                $0.scope == scope && !$0.tombstoned && $0.type == "sleep_analysis" &&
                $0.endAt != nil && $0.endAt! >= from && $0.endAt! <= until
            })
            let decoder = Wire.decoder()
            let samples = try modelContext.fetch(query).map { try decoder.decode(HealthSample.self, from: $0.payload) }
            let nights = SleepHistory.nights(samples: samples, zone: zone, days: missing, now: now)
            let computed = Dictionary(uniqueKeysWithValues: nights.map { ($0.date, $0) })
            for day in missing {
                let date = DayKey.string(day, zone: zone)
                if let night = computed[date] { found[date] = night }
                try saveCache(scope: scope, kind: "sleep_cache", entry: SleepDayCache(date: date, timezone: zone, night: computed[date]))
            }
            try modelContext.save()
        }
        return visible.compactMap { found[DayKey.string($0, zone: zone)] }
    }
    func overview(scope: String, zone: String, now: Date, water: Int, since: Date) throws -> HealthOverviewSnapshot {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone) ?? .current
        let today = calendar.startOfDay(for: now)
        let date = DayKey.string(today, zone: zone)
        let id = stableID(zone + "/" + date + "/" + String(Int(since.timeIntervalSince1970)))
        let key = scope + "/health_overview_cache/" + id
        var lookup = FetchDescriptor<LocalRecord>(predicate: #Predicate { $0.key == key }); lookup.fetchLimit = 1
        if let record = try modelContext.fetch(lookup).first,
           var saved: LocalOverviewCache = try? Wire.read(record.payload), saved.algorithm == 1,
           saved.timezone == zone, saved.date == date, saved.since == since {
            if saved.water != water {
                saved.water = water
                saved.snapshot.summary.metrics["water_ml"] = HealthMetric(value: Double(water), unit: "ml", source: "app", samples: 0, coverage: "logged_only", method: "today_logged_sum")
                record.payload = try Wire.data(saved); record.updatedAt = now
                try modelContext.save()
            }
            return saved.snapshot
        }
        overviewRawScanCount += 1
        let count = try modelContext.fetchCount(FetchDescriptor<LocalHealthRecord>(predicate: #Predicate { $0.scope == scope && !$0.tombstoned && $0.endAt != nil && $0.endAt! >= since }))
        var samples: [HealthSample] = [], latest: [HealthSample] = []
        let decoder = Wire.decoder()
        for type in LocalHealthOverview.names.keys.sorted() {
            var newest = FetchDescriptor<LocalHealthRecord>(predicate: #Predicate { $0.scope == scope && !$0.tombstoned && $0.type == type && $0.endAt != nil && $0.endAt! >= since }, sortBy: [SortDescriptor(\.endAt, order: .reverse)])
            newest.fetchLimit = 1
            if let row = try modelContext.fetch(newest).first { let s = try decoder.decode(HealthSample.self, from: row.payload); latest.append(s); samples.append(s) }
            guard !["height_cm", "waist_cm", "body_fat_percentage", "bmi", "lean_body_mass", "vo2_max", "workout"].contains(type) else { continue }
            let days = type == "body_mass" ? 13 : type == "sleep_analysis" ? 2 : 1
            let from = max(since, calendar.date(byAdding: .day, value: -days, to: today)!)
            let end = ["body_mass", "sleep_analysis"].contains(type) ? now : today
            let q = FetchDescriptor<LocalHealthRecord>(predicate: #Predicate { $0.scope == scope && !$0.tombstoned && $0.type == type && $0.endAt != nil && $0.endAt! >= from && $0.endAt! <= end })
            for row in try modelContext.fetch(q) { if row.sampleId != latest.last?.healthkitUuid { samples.append(try decoder.decode(HealthSample.self, from: row.payload)) } }
        }
        let result = HealthOverviewSnapshot(count: count, latest: latest, summary: LocalHealthOverview.make(samples: samples, zone: zone, now: now, water: water))
        let record = try modelContext.fetch(lookup).first ?? LocalRecord(scope: scope, kind: "health_overview_cache", id: id, payload: Data())
        if record.modelContext == nil { modelContext.insert(record) }
        record.payload = try Wire.data(LocalOverviewCache(timezone: zone, date: date, since: since, water: water, snapshot: result)); record.updatedAt = now
        try modelContext.save()
        return result
    }
}
