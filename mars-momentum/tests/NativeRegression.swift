import Foundation

// Native regression checks never read or change the user's real credentials.
enum Keychain {
    static func get(_ key: String) -> String? { nil }
    static func set(_ value: String, for key: String) throws {}
    static func delete(_ key: String) {}
}

@main
struct NativeRegression {
    @MainActor
    static func main() throws {
        precondition(Format.duration(5_400) == "1h 30m")
        precondition(Format.shortDuration(3_660) == "1h")
        precondition(Format.shortDuration(5_400) == "1.5h")
        for amount in [Double.greatestFiniteMagnitude, Double(Int.max) * 60, .infinity, .nan, -1] {
            precondition(!Format.duration(amount).isEmpty)
            precondition(!Format.shortDuration(amount).isEmpty)
        }
        print("PASS: duration formatters handle normal, huge and non-finite totals")

        let stamp = Date(timeIntervalSince1970: 1_789_372_800.875)
        let a = Entry(date: stamp, category: .study, kind: .duration, amount: 3_600)
        let b = Entry(date: stamp, category: .gym, kind: .number, amount: 2)
        let remote = SyncDoc(entries: [a], tombstones: [], goals: ["study": Goal(kind: .duration, amount: 3600)], goalsUpdatedAt: stamp)
        let local = SyncDoc(entries: [b], tombstones: [Tombstone(id: a.id, deletedAt: stamp)], goals: [:], goalsUpdatedAt: stamp.addingTimeInterval(-1))
        let merged = remote.mergingLocal(local, preferLocalGoals: true)
        precondition(merged.entries == [b] && merged.tombstones.count == 1 && merged.goals.isEmpty)
        print("PASS: sync merge preserves pending additions, deletions and removed goals")

        let roundTrip = try MarsJSON.makeDecoder().decode(SyncDoc.self, from: MarsJSON.makeEncoder().encode(remote))
        precondition(abs(roundTrip.goalsUpdatedAt!.timeIntervalSince(stamp)) < 0.001)
        precondition(abs(roundTrip.entries[0].date.timeIntervalSince(stamp)) < 0.001)
        print("PASS: JSON round trips preserve subsecond goal conflict timestamps")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mars-native-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EntryStore(fileURL: directory.appendingPathComponent("entries.json"))
        store.add(category: .study, kind: .duration, amount: .greatestFiniteMagnitude, on: .now)
        store.add(category: .study, kind: .duration, amount: .greatestFiniteMagnitude, on: .now)
        store.add(category: .gym, kind: .number, amount: .infinity, on: .now)
        precondition(store.entries.count == 2)
        precondition(store.dayLevels(filter: .study).values.first == 4)
        precondition(!store.totalSummary(filter: .study).isEmpty)
        store.updateGoals([.study: Goal(kind: .duration, amount: 3600)])
        precondition(store.dayLevels(filter: .study).values.first == 4)
        print("PASS: huge synced totals do not overflow heatmap integer conversion")

        let reloaded = EntryStore(fileURL: directory.appendingPathComponent("entries.json"))
        precondition(reloaded.entries.map(\.id) == store.entries.map(\.id))
        precondition(reloaded.entries.map(\.amount) == store.entries.map(\.amount))
        precondition(reloaded.goals == store.goals)
        print("PASS: native persistence retains large finite entries and goals")
        print("5 native regression groups passed")
    }
}
