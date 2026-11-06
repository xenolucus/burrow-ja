import SwiftUI

struct TotalRecord: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let bytes: Int64
    let date: Date
}

/// Mole's history keeps only recent runs, so every real run is copied here and stays counted.
enum TotalsStore {
    private static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "burrow-ja")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("totals.json")
    }

    static func load() -> [TotalRecord] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([TotalRecord].self, from: $0) } ?? []
    }

    private static func save(_ records: [TotalRecord]) {
        // Atomic: a crash mid-write must not lose the running total.
        try? JSONEncoder().encode(records).write(to: file, options: .atomic)
    }

    static func merged(_ records: [TotalRecord], with sessions: [HistoryResult.Session]) -> [TotalRecord] {
        let known = Set(records.map(\.id))
        return records + sessions.compactMap { session -> TotalRecord? in
            guard !session.isPreview, !known.contains(session.id),
                  let bytes = session.size.flatMap(ByteSize.first), bytes > 0 else { return nil }
            return TotalRecord(id: session.id, kind: session.baseCommand, bytes: bytes, date: session.startedDate ?? Date())
        }
    }

    static func sync() async -> [TotalRecord] {
        let current = load()
        guard let history = try? await Mole.json(HistoryResult.self, ["history", "--json", "--limit", "200"]) else { return current }
        let records = merged(current, with: history.sessions ?? [])
        if records != current { save(records) }
        return records
    }

    /// Burrow's own moves to a drive's Trash never reach Mole's history.
    static func addExternal(bytes: Int64) {
        guard bytes > 0 else { return }
        save(load() + [TotalRecord(id: UUID().uuidString, kind: "external", bytes: bytes, date: Date())])
    }

    static func title(_ kind: String) -> String {
        switch kind {
        case "clean": "クリーン"
        case "uninstall": "アンインストール"
        case "optimize": "最適化"
        case "purge": "プロジェクト"
        case "slim": "スリム化"
        case "external": "外付けドライブ"
        default: kind
        }
    }

    static func breakdown(_ records: [TotalRecord]) -> [(kind: String, bytes: Int64, runs: Int)] {
        Dictionary(grouping: records, by: \.kind)
            .map { ($0.key, $0.value.map(\.bytes).reduce(0, +), $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }
}

struct TotalsPage: View {
    @ViewState private var records = TotalsStore.load()

    private var total: Int64 { records.map(\.bytes).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GlowCard(glow: .violet, style: .rim, padding: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("これまでの合計").cardTitle()
                    MetricValue(value: total.metric.value, unit: total.metric.unit, dot: 7)
                    if let first = records.map(\.date).min() {
                        Text("\(first.formatted(date: .long, time: .omitted)) から \(records.count) 回の実行").caption()
                    }
                }
            }
            if records.isEmpty {
                EmptyState(symbol: "chart.bar", text: "まだ記録がありません。",
                           detail: "クリーンなどを実行すると、ここに集計されます。")
            }
            ForEach(TotalsStore.breakdown(records), id: \.kind) { row in
                GlowCard(glow: .graphite, style: .plain, padding: 18) {
                    HStack {
                        Text(TotalsStore.title(row.kind)).font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text("\(row.runs) 回").caption()
                        Text(row.bytes.bytesText).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                            .frame(minWidth: 110, alignment: .trailing)
                    }
                }
            }
            if !records.isEmpty {
                Text("ゴミ箱に移した分も含みます。ゴミ箱を空にするまで、ディスクの空き容量は増えません。").caption()
            }
        }
        .task { records = await TotalsStore.sync() }
    }
}
