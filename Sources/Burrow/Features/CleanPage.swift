import SwiftUI

struct CleanPage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var scan: Scan<SectionReport>
    @AppStorage("clean.includeSystem") private var includeSystem = false
    @ViewState private var confirm: ConfirmAction?

    var body: some View {
        let report = scan.current
        VStack(alignment: .leading, spacing: 22) {
            // While scanning, the running row sum; afterwards Mole's de-duplicated total.
            HeroCard(glow: .magenta, label: scan.scanning ? "Found so far" : "Ready to clean",
                     bytes: scan.scanning ? report?.bytes : report?.total,
                     atLeast: !scan.scanning && (report?.potentialIsLowerBound ?? false),
                     detail: detail,
                     scanning: scan.scanning, progress: progress, started: scan.startedAt, checked: scan.finishedAt, error: scan.error) {
                ScanButton(scanning: scan.scanning, start: scan.start, stop: scan.cancel)
                Button("Clean now") { askToClean() }
                    .buttonStyle(.pill)
                    .disabled(scan.scanning || (scan.report?.total ?? 0) == 0)
            }

            HStack(spacing: 14) {
                Toggle(isOn: $includeSystem) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include system caches").font(.system(size: 13, weight: .medium))
                        Text("Mole asks for your administrator password while cleaning").caption()
                    }
                }
                .toggleStyle(.switch)
                Spacer()
                Button { model.page = .settings } label: { Label("Protected paths", systemImage: "lock.shield") }
                    .buttonStyle(.pillSecondary)
            }

            if let report {
                Notes(notes: report.notes.filter { !$0.contains("System caches need sudo") })
                if report.sections.isEmpty, !scan.scanning {
                    EmptyState(symbol: "checkmark.seal", text: "Nothing to clean right now.")
                } else {
                    SectionGrid(sections: report.sections, glow: .magenta)
                }
            } else if scan.error != nil {
                EmptyState(symbol: "exclamationmark.triangle", text: "The preview did not finish",
                           detail: scan.error ?? "", actionTitle: "Try again", action: scan.start)
            }
        }
        .confirmation($confirm)
        .onAppear(perform: scan.startIfNeeded)
        .onChange(of: model.askCleanAt, initial: true) { _, at in
            guard let at else { return }
            model.askCleanAt = nil
            guard Date().timeIntervalSince(at) < 5 else { return }
            // A window just reopened from the menu bar drops an alert shown in its first layout.
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if NSApp.burrowWindow?.isVisible == true, model.page == .clean, !scan.scanning,
                   (scan.report?.total ?? 0) > 0 { askToClean() }
            }
        }
    }

    private var detail: String {
        guard let report = scan.report else { return "Mole previews everything first. Nothing is removed until you press Clean." }
        let tally = report.tally.map { $0 + ". " } ?? ""
        return tally + "Files listed twice below are counted once."
    }

    private var progress: String {
        [scan.section, scan.status].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func askToClean() {
        let size = (scan.report?.total.bytesText ?? "") + (scan.report?.potentialIsLowerBound == true ? "+" : "")
        confirm = .init(title: "Clean \(size)?",
                        message: "Mole removes the caches and logs listed here. Protected paths are skipped."
                            + (includeSystem ? " System caches need your administrator password." : ""),
                        button: "Clean") {
            model.run("Cleaning your Mac", ["clean"], plan: scan.report?.total,
                      responders: [.when("System caches need sudo", send: includeSystem ? "\r" : " ")]) {
                scan.start()
            }
        }
    }
}

/// "Rescan" that turns into "Stop" while Mole is scanning. ⌘R either way.
struct ScanButton: View {
    let scanning: Bool
    var title = "Rescan"
    let start: () -> Void
    let stop: () -> Void

    var body: some View {
        Button(scanning ? "Stop" : title) { scanning ? stop() : start() }
            .buttonStyle(.pillSecondary)
            .keyboardShortcut("r", modifiers: .command)
            .help(scanning ? "Stop the scan (⌘R)" : "Scan again (⌘R)")
    }
}

struct OptimizePage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var scan: Scan<SectionReport>

    var body: some View {
        let report = scan.current
        VStack(alignment: .leading, spacing: 22) {
            GlowCard(glow: .sage, style: .rim, padding: 26) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Maintenance").cardTitle()
                        Spacer()
                        if scan.scanning {
                            ScanningBadge(started: scan.startedAt).transition(.blurFade)
                        } else if let at = scan.finishedAt {
                            CheckedAgo(date: at).transition(.blurFade)
                        }
                    }
                    .frame(height: 28)
                    HStack(alignment: .bottom, spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            Group {
                                if scan.error != nil, !scan.scanning {
                                    Label("Mole could not finish", systemImage: "exclamationmark.triangle.fill")
                                        .font(.system(size: 24, weight: .semibold)).symbolRenderingMode(.multicolor)
                                } else if scan.report == nil {
                                    Text(scan.scanning ? "Checking…" : "Not checked yet")
                                        .font(.system(size: 26, weight: .medium)).shimmer(scan.scanning)
                                } else {
                                    MetricValue(value: "\(pendingSteps)", unit: pendingSteps == 1 ? "step to run" : "steps to run", dot: 7)
                                }
                            }
                            .frame(minHeight: 84, alignment: .bottomLeading)
                            Text(footnote).font(.system(size: 12))
                                .foregroundStyle(scan.error != nil && !scan.scanning ? Theme.danger : Theme.secondaryText)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 10) {
                            ScanButton(scanning: scan.scanning, title: "Recheck", start: scan.start, stop: scan.cancel)
                            Button("Optimize") {
                                model.run("Optimizing", ["optimize"]) { scan.start() }
                            }
                            .buttonStyle(.pill).disabled(scan.scanning || scan.report == nil)
                        }
                        .fixedSize()
                    }
                }
            }
            .frame(minHeight: 216)
            .fixedSize(horizontal: false, vertical: true)
            .animation(Motion.spring, value: scan.scanning)

            if let report {
                if !report.notes.isEmpty {
                    GlowCard(glow: .ember, style: .core, padding: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Performance diagnosis").cardTitle()
                            Notes(notes: report.notes)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "eye")
                    Text("Preview: these steps run when you press Optimize.")
                }
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14).frame(height: 32)
                .background(Capsule().fill(Glow.sage.color.opacity(0.22)))
                .overlay(Pill().strokeBorder(Glow.sage.color.opacity(0.5)))
                SectionGrid(sections: report.sections, glow: .sage, preview: true)
            } else if scan.error != nil {
                EmptyState(symbol: "exclamationmark.triangle", text: "The check did not finish",
                           detail: scan.error ?? "", actionTitle: "Try again", action: scan.start)
            }
        }
        .onAppear(perform: scan.startIfNeeded)
    }

    private var footnote: String {
        if scan.scanning { return scan.section.isEmpty ? "Mole is looking at your system…" : "Checking \(scan.section)" }
        if let error = scan.error { return error }
        if let tally = scan.report?.summary.first(where: { $0.contains("unchanged") }) { return tally.replacingOccurrences(of: " | ", with: " · ") }
        return "Finder, DNS, Spotlight, preferences and more. Mole asks before anything needs your password."
    }

    /// Steps Mole would run, from its "Would apply N optimizations" summary.
    private var pendingSteps: Int {
        let line = scan.report?.summary.first { $0.contains("Would apply") } ?? ""
        return line.split(separator: " ").compactMap { Int($0) }.first ?? 0
    }
}
