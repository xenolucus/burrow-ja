import AppKit
import IOKit
import SwiftUI

/// Power flowing right now, from the battery controller. Mole's `adapter_power` is the charger's
/// rating, not what it delivers, so this reads the live telemetry instead.
final class PowerMeter {
    struct Reading: Equatable {
        let inputWatts: Double
        let loadWatts: Double
        /// At the recent average load; nil on a Mac without a battery.
        let hoursLeft: Double?
    }

    /// About a minute of samples, so one busy moment does not swing the estimate.
    private var loads: [Double] = []

    static func hours(milliampHours: Double, millivolts: Double, watts: Double) -> Double? {
        watts > 0.5 && milliampHours > 0 ? milliampHours * millivolts / 1_000_000 / watts : nil
    }

    func read() -> Reading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let info = props?.takeRetainedValue() as? [String: Any],
              let telemetry = info["PowerTelemetryData"] as? [String: Any],
              let load = telemetry["SystemLoad"] as? Double else { return nil }
        let watts = load / 1000
        loads = Array((loads + [watts]).suffix(30))
        let average = loads.reduce(0, +) / Double(loads.count)
        let battery = info["BatteryData"] as? [String: Any]
        let remaining = battery?["RemainingCapacity"] as? Double ?? 0
        let volts = info["Voltage"] as? Double ?? 0
        return Reading(inputWatts: (telemetry["SystemPowerIn"] as? Double ?? 0) / 1000, loadWatts: watts,
                       hoursLeft: Self.hours(milliampHours: remaining, millivolts: volts, watts: average))
    }
}

/// How the columns look in the menu bar.
enum MenuStyle: String, CaseIterable, Identifiable {
    case stacked, inline, gauge, symbol, pill, bold, mini, underline

    static let storageKey = "menuStyle"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .stacked: "2段"
        case .inline: "1行"
        case .gauge: "メーター"
        case .symbol: "アイコン"
        case .pill: "枠"
        case .bold: "太字"
        case .mini: "極小"
        case .underline: "下線メーター"
        }
    }

    /// These draw the same with labels off; the older styles swap to a larger value instead.
    var keepsLayoutWithoutLabels: Bool { self == .pill || self == .bold || self == .mini || self == .underline }
}

/// One live value in the menu bar.
enum MenuMetric: String, CaseIterable, Identifiable {
    case cpu, memory, temperature, battery, power, runtime, disk, network

    static let storageKey = "menuMetrics"
    static let defaultValue = "cpu,memory,network"
    static let labelsKey = "menuLabels"
    static let gapKey = "menuGap"
    static let defaultGap = 8.0
    static let intervalKey = "menuInterval"
    static let defaultInterval = 5

    /// How often `mo status` samples; every value and the card share this one stream.
    static var intervalArgument: String {
        let seconds = UserDefaults.standard.integer(forKey: intervalKey)
        return "\(seconds > 0 ? seconds : defaultInterval)s"
    }

    /// Nothing can read the menu bar while the screens sleep, so the stream stops with them.
    static func pauseWhileScreensSleep(_ monitor: StatusMonitor) {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { monitor.pause() }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { monitor.resume() }
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "メモリ"
        case .temperature: "温度"
        case .battery: "バッテリー残量"
        case .power: "入力と消費の電力"
        case .runtime: "使える時間の目安"
        case .disk: "空き容量"
        case .network: "ネットワーク"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .temperature: "thermometer.medium"
        case .battery: "battery.75percent"
        case .power: "bolt.fill"
        case .runtime: "clock"
        case .disk: "internaldrive"
        case .network: "arrow.up.arrow.down"
        }
    }

    struct Cell: Equatable {
        var top: String
        var bottom: String
        /// The widest text the value can reach, so columns never jump as numbers change.
        var widest: String
        /// 0...1 for the meter style; nil when a bar means nothing.
        var fraction: Double?
        /// Both lines are values, drawn at the same size and right-aligned.
        var pair = false

        /// Keeps the arrows, which carry meaning; "入" and "使" go with the other labels.
        func withoutLabels() -> Cell {
            var cell = self
            cell.top = top.replacingOccurrences(of: "入 ", with: "")
            cell.bottom = bottom.replacingOccurrences(of: "使 ", with: "")
            cell.widest = widest.replacingOccurrences(of: "使 ", with: "")
            return cell
        }
    }

    /// nil when this Mac does not report the value.
    func cell(_ s: SystemStatus, power: PowerMeter.Reading?) -> Cell? {
        switch self {
        case .cpu:
            return s.cpu.map { Cell(top: "CPU", bottom: String(format: "%.0f%%", $0.usage), widest: "100%", fraction: $0.usage / 100) }
        case .memory:
            return s.memory.map { Cell(top: "MEM", bottom: String(format: "%.0f%%", $0.used_percent), widest: "100%", fraction: $0.used_percent / 100) }
        case .temperature:
            // Some Macs report 0 for the CPU sensor; the battery sensor still works there.
            let celsius = [s.thermal?.cpu_temp, s.thermal?.battery_temp].compactMap { $0 }.first { $0 > 0 }
            return celsius.map { Cell(top: "TEMP", bottom: String(format: "%.0f℃", $0), widest: "100℃", fraction: min($0 / 100, 1)) }
        case .battery:
            return s.batteries?.first?.percent.map { Cell(top: "BAT", bottom: String(format: "%.0f%%", $0), widest: "100%", fraction: $0 / 100) }
        case .power:
            return power.map { Cell(top: String(format: "入 %.0fW", $0.inputWatts), bottom: String(format: "使 %.0fW", $0.loadWatts), widest: "使 188W", pair: true) }
        case .runtime:
            return power?.hoursLeft.map { Cell(top: "残り", bottom: Self.hoursText($0), widest: "88.8h") }
        case .disk:
            return s.rootDisk.map { Cell(top: "SSD", bottom: Self.storage($0.total - $0.used), widest: "888G",
                                         fraction: Double($0.used) / Double(max($0.total, 1))) }
        case .network:
            guard let rows = s.network else { return nil }
            let up = rows.compactMap(\.tx_rate_mbs).reduce(0, +), down = rows.compactMap(\.rx_rate_mbs).reduce(0, +)
            return Cell(top: "↑" + Self.speed(up), bottom: "↓" + Self.speed(down), widest: "↓888K", pair: true)
        }
    }

    static func speed(_ megabytes: Double) -> String {
        if megabytes < 0.995 { return String(format: "%.0fK", megabytes * 1000) }
        return String(format: megabytes < 9.95 ? "%.1fM" : "%.0fM", megabytes)
    }

    static func hoursText(_ hours: Double) -> String {
        String(format: hours < 10 ? "%.1fh" : "%.0fh", hours)
    }

    private static func storage(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000_000 ? String(format: "%.1fT", Double(bytes) / 1e12) : String(format: "%.0fG", Double(bytes) / 1e9)
    }

    static func selected(_ stored: String) -> [MenuMetric] {
        stored.split(separator: ",").compactMap { MenuMetric(rawValue: String($0)) }
    }

    /// The new order after moving `metric` by `offset`, or nil at either end.
    static func moved(_ metric: MenuMetric, by offset: Int, in order: [MenuMetric]) -> [MenuMetric]? {
        guard let index = order.firstIndex(of: metric), order.indices.contains(index + offset) else { return nil }
        var result = order
        result.swapAt(index, index + offset)
        return result
    }

    private static let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .medium)]
    private static let value: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)]
    private static let line: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
    private static let bold: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)]
    private static let tiny: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)]

    /// One template image, so the menu bar tints it for light, dark and wallpaper.
    /// The app icon appears only when no value is on, so the item never disappears.
    static func image(_ metrics: [MenuMetric], style: MenuStyle, labels: Bool, gap: CGFloat, status: SystemStatus?, power: PowerMeter.Reading?) -> NSImage {
        let cells = status.map { s in
            metrics.compactMap { m in m.cell(s, power: power).map { (m, labels ? $0 : $0.withoutLabels()) } }
        } ?? []
        guard !cells.isEmpty else { return TrayIcon.image }
        let widths = cells.map { columnWidth($0.0, $0.1, style, labels: labels) }
        let width = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            var x: CGFloat = 0
            for ((metric, cell), columnWidth) in zip(cells, widths) {
                draw(metric, cell, style, labels: labels, x: x, width: columnWidth)
                x += columnWidth + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = cells.map { "\($0.0.title) \($0.1.top) \($0.1.bottom)" }.joined(separator: "、")
        return image
    }

    private static func measure(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: attributes).size().width)
    }

    private static func columnWidth(_ metric: MenuMetric, _ cell: Cell, _ style: MenuStyle, labels: Bool) -> CGFloat {
        if !labels, !cell.pair, style != .inline, !style.keepsLayoutWithoutLabels {
            return (style == .gauge ? 7 : 0) + measure(cell.widest, line)
        }
        switch style {
        case .pill where cell.pair:
            return measure(cell.widest, value) + 10
        case .pill:
            return measure(cell.widest, line) + 10
        case .bold where !cell.pair:
            return measure(cell.widest, bold)
        case .mini:
            return cell.pair ? measure(cell.widest, tiny) : measure(miniLabel(cell, labels) + cell.widest, tiny)
        case .underline where !cell.pair:
            return measure(cell.widest, line)
        case .inline where cell.pair:
            return measure(cell.widest + " " + cell.widest, line)
        case .inline:
            return measure(cell.top + " ", small) + measure(cell.widest, line)
        case .symbol where !cell.pair:
            return 15 + measure(cell.widest, line)
        case .gauge where !cell.pair:
            return 7 + max(measure(cell.top, small), measure(cell.widest, value))
        default:
            return max(measure(cell.widest, value), cell.pair ? 0 : measure(cell.top, small))
        }
    }

    private static func miniLabel(_ cell: Cell, _ labels: Bool) -> String { labels ? cell.top + " " : "" }

    private static func draw(_ metric: MenuMetric, _ cell: Cell, _ style: MenuStyle, labels: Bool, x: CGFloat, width: CGFloat) {
        func text(_ string: String, _ attributes: [NSAttributedString.Key: Any], right: CGFloat, y: CGFloat) {
            let drawn = NSAttributedString(string: string, attributes: attributes)
            drawn.draw(at: NSPoint(x: right - ceil(drawn.size().width), y: y))
        }
        let right = x + width
        func gauge() {
            NSColor.black.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: 3, height: 18), xRadius: 1.5, yRadius: 1.5).fill()
            NSColor.black.setFill()
            let height = 18 * CGFloat(min(max(cell.fraction ?? 0, 0), 1))
            NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
        }
        if !labels, !cell.pair, !style.keepsLayoutWithoutLabels {
            if style == .gauge { gauge() }
            return text(cell.bottom, line, right: right, y: 3)
        }
        switch style {
        case .pill:
            NSColor.black.setStroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: x + 0.5, y: 1.5, width: width - 1, height: 19), xRadius: 5, yRadius: 5)
            frame.lineWidth = 1
            frame.stroke()
            if cell.pair {
                text(cell.top, value, right: right - 5, y: 10)
                text(cell.bottom, value, right: right - 5, y: 1)
            } else {
                text(cell.bottom, line, right: right - 5, y: 3)
            }
        case .bold where !cell.pair:
            text(cell.bottom, bold, right: right, y: 2)
        case .mini where cell.pair:
            text(cell.top, tiny, right: right, y: 11)
            text(cell.bottom, tiny, right: right, y: 1)
        case .mini:
            text(miniLabel(cell, labels) + cell.bottom, tiny, right: right, y: 5)
        case .underline where !cell.pair:
            text(cell.bottom, line, right: right, y: 6)
            NSColor.black.withAlphaComponent(0.3).setFill()
            NSBezierPath(rect: NSRect(x: x, y: 2, width: width, height: 2)).fill()
            NSColor.black.setFill()
            NSBezierPath(rect: NSRect(x: x, y: 2, width: width * CGFloat(min(max(cell.fraction ?? 0, 0), 1)), height: 2)).fill()
        case .inline where cell.pair:
            text(cell.bottom, line, right: right, y: 3)
            text(cell.top, line, right: right - measure(cell.widest + " ", line), y: 3)
        case .inline:
            NSAttributedString(string: cell.top, attributes: small).draw(at: NSPoint(x: x, y: 6))
            text(cell.bottom, line, right: right, y: 3)
        case .symbol where !cell.pair:
            if let image = NSImage(systemSymbolName: metric.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) {
                image.draw(in: NSRect(x: x, y: 11 - image.size.height / 2, width: image.size.width, height: image.size.height))
            }
            text(cell.bottom, line, right: right, y: 3)
        case _ where cell.pair:
            text(cell.top, value, right: right, y: 11)
            text(cell.bottom, value, right: right, y: 0)
        case .gauge:
            gauge()
            text(cell.top, small, right: right, y: 11)
            text(cell.bottom, value, right: right, y: 0)
        default:
            text(cell.top, small, right: right, y: 11)
            text(cell.bottom, value, right: right, y: 0)
        }
    }
}

struct TrayLabel: View {
    @ObservedObject var monitor: StatusMonitor
    @AppStorage(MenuMetric.storageKey) private var stored = MenuMetric.defaultValue
    @AppStorage(MenuStyle.storageKey) private var style = MenuStyle.stacked.rawValue
    @AppStorage(MenuMetric.labelsKey) private var labels = true
    @AppStorage(MenuMetric.gapKey) private var gap = MenuMetric.defaultGap

    var body: some View {
        Image(nsImage: MenuMetric.image(MenuMetric.selected(stored), style: MenuStyle(rawValue: style) ?? .stacked,
                                        labels: labels, gap: gap, status: monitor.status, power: monitor.power))
    }
}

/// Input, load and the time left, in the menu bar card.
struct PowerRow: View {
    @ObservedObject var monitor: StatusMonitor

    var body: some View {
        if let power = monitor.power {
            HStack {
                item("入力", String(format: "%.1f W", power.inputWatts))
                Spacer()
                item("消費", String(format: "%.1f W", power.loadWatts))
                Spacer()
                item("このまま使うと", power.hoursLeft.map { "約 " + MenuMetric.hoursText($0) } ?? "–")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
        }
    }

    private func item(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
        }
    }
}

struct MenuMetricsCard: View {
    @ObservedObject var monitor: StatusMonitor
    @AppStorage(MenuMetric.storageKey) private var stored = MenuMetric.defaultValue
    @AppStorage(MenuStyle.storageKey) private var style = MenuStyle.stacked.rawValue
    @AppStorage(MenuMetric.labelsKey) private var labels = true
    @AppStorage(MenuMetric.gapKey) private var gap = MenuMetric.defaultGap
    @AppStorage(MenuMetric.intervalKey) private var interval = MenuMetric.defaultInterval

    private var selected: [MenuMetric] { MenuMetric.selected(stored) }

    var body: some View {
        GlowCard(glow: .blue, style: .rim, padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Text("メニューバーの表示").cardTitle()
                Text("オンにした順に左から並びます。矢印で順番を変えられます。すべてオフにすると測定を止めます。").caption()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(selected + MenuMetric.allCases.filter { !selected.contains($0) }) { metric in row(metric) }
                }
                Toggle("ラベルを表示（CPU、MEM、入、使など）", isOn: $labels)
                    .font(.system(size: 13)).toggleStyle(.switch).controlSize(.small)
                HStack(spacing: 12) {
                    Text("値どうしの間隔").font(.system(size: 13)).frame(width: 110, alignment: .leading)
                    Slider(value: $gap, in: 2...24, step: 1).accessibilityLabel("値どうしの間隔")
                    Text("\(Int(gap)) pt").font(.system(size: 13, weight: .medium)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                HStack(spacing: 12) {
                    Text("更新の間隔").font(.system(size: 13)).frame(width: 110, alignment: .leading)
                    Picker("更新の間隔", selection: $interval) {
                        ForEach([2, 5, 10, 30], id: \.self) { Text("\($0)秒").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
                    .onChange(of: interval) { _, _ in
                        if monitor.isRunning { monitor.stop(); monitor.start() }
                    }
                }
                Text("間隔を長くすると、バッテリーと CPU の負荷が減ります。画面がスリープすると測定を止めます。").caption()
                Text("デザイン").font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(MenuStyle.allCases) { option in preview(option) }
                }
            }
        }
    }

    private func row(_ metric: MenuMetric) -> some View {
        HStack(spacing: 6) {
            Toggle(metric.title, isOn: binding(metric)).font(.system(size: 13)).toggleStyle(.switch).controlSize(.small)
            Spacer()
            if selected.contains(metric) {
                arrow("chevron.up", "\(metric.title) を前へ", metric, by: -1)
                arrow("chevron.down", "\(metric.title) を後ろへ", metric, by: 1)
            }
        }
    }

    private func arrow(_ symbol: String, _ label: String, _ metric: MenuMetric, by offset: Int) -> some View {
        Button { save(MenuMetric.moved(metric, by: offset, in: selected) ?? selected) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(MenuMetric.moved(metric, by: offset, in: selected) == nil)
        .accessibilityLabel(label)
    }

    private func preview(_ option: MenuStyle) -> some View {
        Button { style = option.rawValue } label: {
            HStack(spacing: 10) {
                Image(systemName: style == option.rawValue ? "checkmark.circle.fill" : "circle")
                Text(option.title).font(.system(size: 13)).frame(width: 84, alignment: .leading)
                Image(nsImage: MenuMetric.image(selected, style: option, labels: labels, gap: gap, status: monitor.status, power: monitor.power))
                    .renderingMode(.template)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(style == option.rawValue ? 0.12 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("デザイン: \(option.title)")
    }

    private func save(_ metrics: [MenuMetric]) {
        stored = metrics.map(\.rawValue).joined(separator: ",")
        if metrics.isEmpty { monitor.release("menubar") } else { monitor.acquire("menubar") }
    }

    private func binding(_ metric: MenuMetric) -> Binding<Bool> {
        Binding {
            selected.contains(metric)
        } set: { on in
            save(selected.filter { $0 != metric } + (on ? [metric] : []))
        }
    }
}
