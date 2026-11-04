import AppKit
import SwiftUI

/// The menu bar card: free space, the Mac's vitals and the tool results at a glance, each a
/// shortcut into the window. Live status streams only while the card is open.
struct TrayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: StatusMonitor
    @ObservedObject var leftovers: LeftoverStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = monitor.status
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
                Text("Burrow").font(.system(size: 14, weight: .semibold))
                Spacer()
                if let score = s?.health_score {
                    Tag(text: "Health \(score)", color: score >= 70 ? Theme.accent : score >= 45 ? .orange : Theme.danger)
                }
            }
            .padding(.horizontal, 4)

            Button { open(.analyze) } label: { diskCard(s) }
                .buttonStyle(.plain).hoverLift().accessibilityHint("Opens Disk Map")

            HStack(spacing: 10) {
                vital("CPU", s.map { String(format: "%.0f", $0.cpu?.usage ?? 0) }, unit: "%", fill: (s?.cpu?.usage ?? 0) / 100, glow: .violet)
                vital("Memory", s.map { String(format: "%.0f", $0.memory?.used_percent ?? 0) }, unit: "%",
                      fill: (s?.memory?.used_percent ?? 0) / 100, glow: .magenta, pressure: monitor.pressure)
                if let b = s?.batteries?.first {
                    vital("Battery", String(format: "%.0f", b.percent ?? 0), unit: "%", fill: (b.percent ?? 0) / 100, glow: .ember)
                } else {
                    // A desktop Mac has no battery: the network takes its place.
                    let rx = (s?.network ?? []).compactMap(\.rx_rate_mbs).reduce(0, +)
                    vital("Network", s.map { _ in String(format: "%.1f", rx) }, unit: "MB/s", fill: min(rx / 10, 1), glow: .ember)
                }
            }

            VStack(spacing: 2) {
                TrayRow(title: "Caches and logs", value: scanValue(model.clean, \.total), busy: model.clean.scanning,
                        clean: canClean ? { open(.clean); model.askCleanAt = Date() } : nil) { open(.clean) }
                row("Leftovers of removed apps", value: leftoversValue, busy: leftovers.scanning, page: .uninstall)
                row("Old installers", value: model.installers.files.map { $0.map(\.bytes).reduce(0, +).bytesText }
                        ?? (model.installers.scanning ? "Looking…" : "Not checked"),
                    busy: model.installers.scanning, page: .installers)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))

            HStack(spacing: 8) {
                Button { open(nil) } label: { Text("Open Burrow").frame(maxWidth: .infinity) }.buttonStyle(.pill)
                // Quit sits behind the menu, away from a stray click.
                Menu {
                    Button("Settings…") { open(.settings) }
                    Divider()
                    Button("Quit Burrow") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(.white.opacity(0.08)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.white)
                .accessibilityLabel("More")
            }
        }
        .padding(14)
        .frame(width: 330)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onAppear { monitor.acquire("tray") }
        .onDisappear { monitor.release("tray") }
    }

    /// Brings the window forward (or back, once closed), on `page` when given.
    private func open(_ page: Page?) {
        model.askCleanAt = nil
        if let page { model.page = page }
        NSApp.activate()
        if let window = NSApp.burrowWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }

    private func diskCard(_ s: SystemStatus?) -> some View {
        let disk = s?.rootDisk
        let free = (disk?.total ?? 0) - (disk?.used ?? 0)
        return GlowCard(glow: .blue, style: .rim, padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Free space").cardTitle()
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondaryText)
                }
                MetricValue(value: disk == nil ? "-" : free.metric.value, unit: (disk == nil ? "GB" : free.metric.unit) + " free",
                            dot: 4.5, live: true)
                DotMeter(value: disk.map { Double($0.used) / Double(max($0.total, 1)) } ?? 0, count: 34)
                Text(disk.map { "\($0.used.bytesText) used of \($0.total.bytesText)" } ?? "Reading the disk…").caption()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// `pressure` colours the memory meter: a full RAM is normal on a Mac, pressure is not.
    private func vital(_ title: String, _ value: String?, unit: String, fill: Double, glow: Glow,
                       pressure: MemoryPressure? = nil) -> some View {
        Button { open(.overview) } label: {
            GlowCard(glow: glow, style: .core, padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        Spacer(minLength: 0)
                        // Only pressure that matters is shown, in words: a full RAM is normal on a Mac.
                        if let pressure, pressure != .normal {
                            Text(pressure.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(pressure.color)
                        }
                    }
                    MetricValue(value: value ?? "-", unit: unit, dot: 3, live: true)
                    DotMeter(value: fill, count: 9, color: pressure == nil || pressure == .normal ? .white : pressure!.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain).hoverLift()
        .accessibilityElement(children: .combine)
        .accessibilityValue(pressure.map { "Memory pressure \($0.label)" } ?? "")
        .accessibilityHint("Opens Overview")
    }

    private func row(_ title: String, value: String, busy: Bool, page: Page) -> some View {
        TrayRow(title: title, value: value, busy: busy) { open(page) }
    }

    /// Cleaning starts from the window's own confirmation and run sheet, never from here.
    private var canClean: Bool {
        !model.clean.scanning && (model.clean.report?.total ?? 0) > 0 && model.session == nil
    }

    private func scanValue<R>(_ scan: Scan<R>, _ bytes: KeyPath<R, Int64>) -> String {
        if let r = scan.report { return r[keyPath: bytes].bytesText }
        return scan.scanning ? "Scanning…" : "Not scanned"
    }

    private var leftoversValue: String {
        guard let all = leftovers.leftovers else { return leftovers.scanning ? "Looking…" : "Not checked" }
        return all.isEmpty ? "None" : all.map(\.bytes).reduce(0, +).bytesText
    }
}

private struct TrayRow: View {
    let title: String
    let value: String
    let busy: Bool
    /// A Clean button on the row, when there is something to clean.
    var clean: (() -> Void)?
    let action: () -> Void
    @ViewState private var hover = false

    var body: some View {
        // The Clean button sits beside the row's own button: a button inside another's label
        // does not reliably get its click.
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13))
                    Spacer()
                    if busy { PulseDot() }
                    Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(Theme.secondaryText)
                    if clean == nil { chevron }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .accessibilityLabel("\(title), \(value)")
            if let clean {
                Button("Clean", action: clean)
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                    .accessibilityLabel("Clean \(title.lowercased()), \(value)")
                    .accessibilityHint("Asks before Mole cleans")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hover ? 0.07 : 0)))
        .animation(Motion.quick, value: hover)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiaryText)
    }
}

/// Burrow's arch, drawn as a template so the menu bar tints it.
enum TrayIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = NSBezierPath()
            let r = rect.insetBy(dx: 2.5, dy: 2.5)
            path.move(to: NSPoint(x: r.minX, y: r.minY))
            path.line(to: NSPoint(x: r.minX, y: r.midY))
            path.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2, startAngle: 180, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: r.maxX, y: r.minY))
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.midX - 2, y: r.minY + 1, width: 4, height: 4)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Burrow"
        return image
    }()
}
