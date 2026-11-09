import SwiftUI

/// One value's own icon, size and position in the menu bar. Stored as JSON so the label redraws on every change.
struct MenuTweak: Codable, Equatable {
    static let storageKey = "menuTweaks"
    static let iconWidth: CGFloat = 14
    static let symbols = ["cpu", "memorychip", "thermometer.medium", "battery.75percent", "bolt.fill", "clock", "internaldrive",
                          "arrow.up.arrow.down", "wifi", "flame", "gauge.with.dots.needle.67percent", "leaf", "star", "heart"]

    var symbol: String?
    var scale = 1.0
    var x = 0.0
    var y = 0.0

    init() {}

    /// Missing fields take their defaults, so a saved tweak from another version still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        // Kept to the sliders' ranges, so a hand-edited value cannot give a zero or negative width.
        scale = min(max(try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1, 0.7), 1.3)
        x = min(max(try container.decodeIfPresent(Double.self, forKey: .x) ?? 0, -6), 6)
        y = min(max(try container.decodeIfPresent(Double.self, forKey: .y) ?? 0, -4), 4)
    }

    /// Each entry on its own, so one unreadable entry never takes the others with it.
    static func load(_ text: String) -> [String: MenuTweak] {
        guard let raw = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return [:] }
        return raw.compactMapValues { value in
            (try? JSONSerialization.data(withJSONObject: value)).flatMap { try? JSONDecoder().decode(MenuTweak.self, from: $0) }
        }
    }

    static func save(_ tweaks: [String: MenuTweak]) -> String {
        let kept = tweaks.filter { $0.value != MenuTweak() }
        return (try? JSONEncoder().encode(kept)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The style's own icon slot takes the choice; other columns get the icon in front.
    func addsIcon(style: MenuStyle, pair: Bool) -> Bool { symbol != nil && (style != .symbol || pair) }

    func width(base: CGFloat, addsIcon: Bool) -> CGFloat {
        (base + (addsIcon ? Self.iconWidth : 0)) * scale
    }
}

struct MenuTweakCard: View {
    @AppStorage(MenuMetric.storageKey) private var stored = MenuMetric.defaultValue
    @AppStorage(MenuTweak.storageKey) private var text = ""
    @ViewState private var chosen: MenuMetric?

    private var selected: [MenuMetric] { MenuMetric.selected(stored) }
    private var metric: MenuMetric? { chosen.flatMap { selected.contains($0) ? $0 : nil } ?? selected.first }

    var body: some View {
        if let metric {
            GlowCard(glow: .blue, style: .rim, padding: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("値ごとの調整").cardTitle()
                        Spacer()
                        Picker("調整する値", selection: Binding { metric } set: { chosen = $0 }) {
                            ForEach(selected) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Text("メニューバーの表示がその場で変わります。").caption()
                    icons(metric)
                    slider("サイズ", tweak(metric, \.scale), 0.7...1.3, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
                    slider("左右の位置", tweak(metric, \.x), -6...6, step: 1) { "\(Int($0)) pt" }
                    slider("上下の位置", tweak(metric, \.y), -4...4, step: 1) { "\(Int($0)) pt" }
                    Text("メニューバーの高さを超えた部分は切れます。").caption()
                    HStack {
                        Spacer()
                        Button("この値を元に戻す") { update(metric) { $0 = MenuTweak() } }.buttonStyle(.link).font(.system(size: 12))
                    }
                }
            }
        }
    }

    private func icons(_ metric: MenuMetric) -> some View {
        let current = MenuTweak.load(text)[metric.rawValue]?.symbol
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 8), alignment: .leading, spacing: 6) {
            iconButton(nil, current: current, metric) { Text("なし").font(.system(size: 11)) }
            ForEach(MenuTweak.symbols, id: \.self) { symbol in
                iconButton(symbol, current: current, metric) { Image(systemName: symbol).font(.system(size: 13)) }
            }
        }
    }

    private func iconButton<Label: View>(_ symbol: String?, current: String?, _ metric: MenuMetric, @ViewBuilder label: () -> Label) -> some View {
        Button { update(metric) { $0.symbol = symbol } } label: {
            label().frame(width: 34, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(symbol == current ? 0.18 : 0.05)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol ?? "アイコンなし")
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).frame(width: 96, alignment: .leading)
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
            Text(format(value.wrappedValue)).font(.system(size: 13, weight: .medium)).monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }

    private func tweak(_ metric: MenuMetric, _ path: WritableKeyPath<MenuTweak, Double>) -> Binding<Double> {
        Binding {
            (MenuTweak.load(text)[metric.rawValue] ?? MenuTweak())[keyPath: path]
        } set: { value in
            update(metric) { $0[keyPath: path] = value }
        }
    }

    private func update(_ metric: MenuMetric, _ change: (inout MenuTweak) -> Void) {
        var tweaks = MenuTweak.load(text)
        var item = tweaks[metric.rawValue] ?? MenuTweak()
        change(&item)
        tweaks[metric.rawValue] = item
        text = MenuTweak.save(tweaks)
    }
}
