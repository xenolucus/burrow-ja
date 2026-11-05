import AppKit
import SwiftUI

/// Live values drawn next to the menu bar icon, one small column per metric.
enum MenuMetric: String, CaseIterable, Identifiable {
    case cpu, memory, temperature, battery, disk, network

    static let storageKey = "menuMetrics"
    static let defaultValue = "cpu,memory,network"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "メモリ"
        case .temperature: "温度"
        case .battery: "バッテリー"
        case .disk: "空き容量"
        case .network: "ネットワーク"
        }
    }

    /// The two lines of a column; nil when this Mac does not report the value.
    func lines(_ s: SystemStatus) -> (top: String, bottom: String)? {
        switch self {
        case .cpu: return s.cpu.map { ("CPU", String(format: "%.0f%%", $0.usage)) }
        case .memory: return s.memory.map { ("MEM", String(format: "%.0f%%", $0.used_percent)) }
        case .temperature: return s.thermal?.cpu_temp.map { ("TEMP", String(format: "%.0f℃", $0)) }
        case .battery: return s.batteries?.first?.percent.map { ("BAT", String(format: "%.0f%%", $0)) }
        case .disk: return s.rootDisk.map { ("SSD", Self.short($0.total - $0.used)) }
        case .network:
            guard let rows = s.network else { return nil }
            let up = rows.compactMap(\.tx_rate_mbs).reduce(0, +), down = rows.compactMap(\.rx_rate_mbs).reduce(0, +)
            return (String(format: "↑%.1f", up), String(format: "↓%.1f", down))
        }
    }

    private static func short(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000_000 ? String(format: "%.1fT", Double(bytes) / 1e12) : String(format: "%.0fG", Double(bytes) / 1e9)
    }

    static func selected(_ stored: String) -> [MenuMetric] {
        let names = stored.split(separator: ",").map(String.init)
        return allCases.filter { names.contains($0.rawValue) }
    }

    /// One template image, so the menu bar tints it for light, dark and wallpaper.
    static func image(_ metrics: [MenuMetric], status: SystemStatus?) -> NSImage {
        let columns = status.map { s in metrics.compactMap { m in m.lines(s).map { (m, $0) } } } ?? []
        guard !columns.isEmpty else { return TrayIcon.image }
        let top: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .medium)]
        let bottom: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)]
        let cells = columns.map { metric, lines in
            let upper = NSAttributedString(string: lines.top, attributes: metric == .network ? bottom : top)
            let lower = NSAttributedString(string: lines.bottom, attributes: bottom)
            return (upper, lower, ceil(max(upper.size().width, lower.size().width)))
        }
        let icon = TrayIcon.image, gap: CGFloat = 7
        let width = icon.size.width + cells.reduce(0) { $0 + gap + $1.2 }
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: 2, width: icon.size.width, height: icon.size.height))
            var x = icon.size.width + gap
            for (upper, lower, cellWidth) in cells {
                upper.draw(at: NSPoint(x: x, y: 11))
                lower.draw(at: NSPoint(x: x, y: 0))
                x += cellWidth + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = columns.map { "\($0.0.title) \($0.1.bottom)" }.joined(separator: "、")
        return image
    }
}

struct TrayLabel: View {
    @ObservedObject var monitor: StatusMonitor
    @AppStorage(MenuMetric.storageKey) private var stored = MenuMetric.defaultValue

    var body: some View {
        Image(nsImage: MenuMetric.image(MenuMetric.selected(stored), status: monitor.status))
    }
}

struct MenuMetricsCard: View {
    let monitor: StatusMonitor
    @AppStorage(MenuMetric.storageKey) private var stored = MenuMetric.defaultValue

    var body: some View {
        GlowCard(glow: .blue, style: .rim, padding: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("メニューバーの表示").cardTitle()
                Text("オンにした値を2秒ごとに更新します。すべてオフにすると測定を止めます。").caption()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 10) {
                    ForEach(MenuMetric.allCases) { metric in
                        Toggle(metric.title, isOn: binding(metric)).font(.system(size: 13))
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private func binding(_ metric: MenuMetric) -> Binding<Bool> {
        Binding {
            MenuMetric.selected(stored).contains(metric)
        } set: { on in
            var chosen = MenuMetric.selected(stored).filter { $0 != metric }
            if on { chosen.append(metric) }
            stored = chosen.map(\.rawValue).joined(separator: ",")
            if chosen.isEmpty { monitor.release("menubar") } else { monitor.acquire("menubar") }
        }
    }
}
