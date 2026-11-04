import SwiftUI

/// Streams `mo status --watch` while the overview is on screen.
@MainActor
final class StatusMonitor: ObservableObject {
    static let historyLength = 32

    @Published var status: SystemStatus?
    @Published var failed: String?
    /// Fixed-length histories (oldest first), so the sparks keep the same bar width from the start.
    @Published var rxHistory = Array(repeating: 0.0, count: historyLength)
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        failed = nil
        task = Task { [weak self] in
            do {
                _ = try await Mole.capture(["status", "--watch", "--interval", "2s"]) { line in self?.ingest(line) }
            } catch {
                if !Task.isCancelled { self?.failed = error.localizedDescription }
            }
            // A stopped stream was already replaced or cleared by stop(); only a stream that
            // ended on its own clears the slot, so a quick restart is never forgotten.
            if !Task.isCancelled { self?.task = nil }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The overview and the menu bar card share one stream: it runs while either is on screen.
    /// A set, so an unpaired appear never keeps it running.
    private var owners = Set<String>()
    func acquire(_ owner: String) {
        owners.insert(owner)
        start()
    }

    func release(_ owner: String) {
        owners.remove(owner)
        if owners.isEmpty { stop() }
    }

    private func ingest(_ line: String) {
        guard let data = line.data(using: .utf8),
              let s = try? JSONDecoder().decode(SystemStatus.self, from: data) else { return }
        status = s
        let rx = (s.network ?? []).compactMap(\.rx_rate_mbs).reduce(0, +)
        rxHistory = Array((rxHistory + [rx]).suffix(Self.historyLength))
    }
}

struct OverviewPage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var monitor: StatusMonitor

    var body: some View {
        let s = monitor.status
        VStack(spacing: 18) {
            HStack(spacing: 18) {
                diskCard(s).frame(maxWidth: .infinity)
                healthCard(s).frame(width: 330)
            }
            .frame(height: 250)

            HStack(spacing: 18) {
                cpuCard(s)
                memoryCard(s)
                batteryCard(s)
                networkCard
            }
            .frame(height: 210)

            HStack(spacing: 18) {
                processesCard(s).frame(maxWidth: .infinity)
                VStack(spacing: 14) {
                    ScanQuickAction(title: "Caches and logs", scan: model.clean, glow: .magenta, bytes: \.total, liveBytes: \.bytes) {
                        model.page = .clean
                    }
                    ScanQuickAction(title: "Project build folders", scan: model.purge, glow: .blue, bytes: \.bytes) {
                        model.page = .projects
                    }
                    InstallersQuickAction(store: model.installers) { model.page = .installers }
                }
                .frame(width: 330)
            }
            .frame(height: 300)
        }
        .redacted(reason: s == nil && monitor.failed == nil ? .placeholder : [])
        .overlay {
            if let failed = monitor.failed {
                EmptyState(symbol: "waveform.path.ecg", text: "Live status stopped", detail: failed,
                           actionTitle: "Restart") { monitor.start() }
                    .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(.black.opacity(0.7)))
            }
        }
        .onAppear { monitor.acquire("overview") }
        .onDisappear { monitor.release("overview") }
    }

    private func diskCard(_ s: SystemStatus?) -> some View {
        let disk = s?.rootDisk
        let free = (disk?.total ?? 0) - (disk?.used ?? 0)
        let used = disk.map { Double($0.used) / Double(max($0.total, 1)) } ?? 0
        return GlowCard(glow: .blue, style: .rim) {
            VStack(alignment: .leading) {
                HStack {
                    Text("Free space").cardTitle()
                    Spacer()
                    if let p = disk?.purgeable, p > 0 { Tag(text: "\(p.bytesText) purgeable") }
                }
                Spacer()
                MetricValue(value: free.metric.value, unit: free.metric.unit + " free", dot: 7, live: true)
                Spacer()
                DotMeter(value: used, count: 48)
                HStack {
                    Text("\(disk?.used.bytesText ?? "–") used").caption()
                    Spacer()
                    Text("\(disk?.total.bytesText ?? "–") total").caption()
                }
            }
        }
    }

    private func healthCard(_ s: SystemStatus?) -> some View {
        let score = s?.health_score ?? 0
        return GlowCard(glow: .sage, style: .core) {
            VStack(alignment: .leading) {
                Text("Health score").cardTitle()
                ZStack(alignment: .bottom) {
                    ArcTicks(value: Double(score) / 100, color: score >= 70 ? Theme.accent : score >= 45 ? .orange : Theme.danger)
                    VStack(spacing: 6) {
                        DotMatrixText(text: "\(score)", dot: 5)
                        Text(s?.health_score_msg ?? "").caption().lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Health score \(score) of 100, \(s?.health_score_msg ?? "")")
                }
            }
        }
    }

    private func cpuCard(_ s: SystemStatus?) -> some View {
        GlowCard(glow: .violet, style: .core, padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("CPU").cardTitle(); Spacer(); Text(s?.hardware?.cpu_model ?? "").caption().lineLimit(1) }
                    .frame(height: 24)
                MetricValue(value: String(format: "%.0f", s?.cpu?.usage ?? 0), unit: "%", dot: 4.5, live: true)
                BarSpark(values: s?.cpu?.per_core ?? [], color: .white, maxValue: 100)
                    .frame(height: 34)
                Text("Load \(String(format: "%.2f", s?.cpu?.load1 ?? 0)) · \(s?.procs ?? 0) procs").caption()
                Spacer(minLength: 0)
            }
        }
    }

    private func memoryCard(_ s: SystemStatus?) -> some View {
        let m = s?.memory
        return GlowCard(glow: .magenta, style: .rim, padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Memory").cardTitle().frame(height: 24)
                MetricValue(value: String(format: "%.0f", m?.used_percent ?? 0), unit: "%", dot: 4.5, live: true)
                DotMeter(value: (m?.used_percent ?? 0) / 100, count: 22)
                Text("\(m?.used.bytesText ?? "–") of \(m?.total.bytesText ?? "–")").caption()
                Spacer(minLength: 0)
            }
        }
    }

    private func batteryCard(_ s: SystemStatus?) -> some View {
        let b = s?.batteries?.first
        return GlowCard(glow: .ember, style: .core, padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Battery").cardTitle(); Spacer(); if let st = b?.status { Tag(text: st) } }
                    .frame(height: 24)
                if let b {
                    MetricValue(value: String(format: "%.0f", b.percent ?? 0), unit: "%", dot: 4.5, live: true)
                    Text([b.health, b.cycle_count.map { "\($0) cycles" }].compactMap { $0 }.joined(separator: " · ")).caption()
                        .lineLimit(1)
                } else {
                    Image(systemName: "powerplug").font(.system(size: 30, weight: .light))
                    Text(s == nil ? "–" : "No battery, on power").caption()
                }
                if let w = s?.thermal?.system_power, w > 0 { Text(String(format: "Drawing %.1f W", w)).caption() }
                Spacer(minLength: 0)
            }
        }
    }

    private var networkCard: some View {
        let s = monitor.status
        let rx = (s?.network ?? []).compactMap(\.rx_rate_mbs).reduce(0, +)
        let tx = (s?.network ?? []).compactMap(\.tx_rate_mbs).reduce(0, +)
        return GlowCard(glow: .graphite, style: .core, padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Network").cardTitle().frame(height: 24)
                MetricValue(value: String(format: "%.1f", rx), unit: "MB/s in", dot: 4.5, live: true)
                // A floor of 1 MB/s keeps an idle line flat instead of blowing tiny noise up to full height.
                BarSpark(values: monitor.rxHistory, color: Theme.accent, maxValue: max(monitor.rxHistory.max() ?? 0, 1))
                    .frame(height: 34)
                Text(String(format: "%.2f MB/s out", tx)).caption()
                Spacer(minLength: 0)
            }
        }
    }

    private func processesCard(_ s: SystemStatus?) -> some View {
        GlowCard(glow: .graphite, style: .plain) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Busiest processes").cardTitle()
                    Spacer()
                    Text(s?.uptime.map { "Up \($0)" } ?? "").caption()
                }
                ForEach(s?.top_processes ?? []) { p in
                    HStack {
                        Text(p.name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        DotMeter(value: min(p.cpu / 100, 1), count: 16, color: p.cpu > 80 ? Glow.ember.color : .white)
                        Text(String(format: "%.0f%%", p.cpu)).font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(Theme.secondaryText).frame(width: 46, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// A shortcut card to a tool page that shows the tool's latest number.
struct QuickAction: View {
    let title: String
    let value: String
    var detail = ""
    var busy = false
    let glow: Glow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlowCard(glow: glow, style: .core, padding: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).caption()
                        HStack(spacing: 8) {
                            Text(value).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                                .monospacedDigit().contentTransition(.numericText())
                            if busy { PulseDot() }
                        }
                        if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1) }
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 32, height: 32).background(Circle().fill(.white))
                }
                .frame(maxHeight: .infinity)
            }
        }
        .buttonStyle(.plain)
        .hoverLift()
        .animation(Motion.quick, value: value)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A quick action backed by a Mole dry run: the last result, live progress, or an invitation.
struct ScanQuickAction<Report>: View {
    let title: String
    @ObservedObject var scan: Scan<Report>
    let glow: Glow
    /// The finished figure, and the running one while Mole scans (they differ for Clean).
    let bytes: KeyPath<Report, Int64>
    var liveBytes: KeyPath<Report, Int64>?
    let action: () -> Void

    var body: some View {
        QuickAction(title: title, value: value, detail: detail, busy: scan.scanning, glow: glow, action: action)
    }

    private var value: String {
        if scan.scanning, let r = scan.current { return r[keyPath: liveBytes ?? bytes].bytesText }
        if let r = scan.report { return r[keyPath: bytes].bytesText }
        if scan.scanning { return "Scanning…" }
        return scan.error == nil ? "Check now" : "Try again"
    }

    private var detail: String {
        if scan.scanning { return "Found so far" }
        if let at = scan.finishedAt { return "Checked \(at.formatted(.relative(presentation: .named)))" }
        return scan.error == nil ? "Scan to see what Mole can free" : "The last scan did not finish"
    }
}

struct InstallersQuickAction: View {
    @ObservedObject var store: InstallerStore
    let action: () -> Void

    var body: some View {
        let files = store.files ?? []
        QuickAction(title: "Old installers",
                    value: store.files == nil ? "Looking…" : files.map(\.bytes).reduce(0, +).bytesText,
                    detail: store.files == nil ? "" : "\(files.count) file\(files.count == 1 ? "" : "s") in Downloads and more",
                    busy: store.scanning, glow: .ember, action: action)
    }
}
