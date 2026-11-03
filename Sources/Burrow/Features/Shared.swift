import SwiftUI

/// The last result of each scan, kept between launches in Burrow's own cache folder (the
/// app's uninstaller removes it). Pages show it at once; a scan runs again only when the user
/// asks or, in the background at launch, when the result is older than `staleAfter`.
enum ResultCache {
    static let staleAfter: TimeInterval = 6 * 3600
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "uz.khan.burrow")

    static func save(_ data: Data, as key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(key), options: .atomic)
    }

    /// The saved output and when it was saved.
    static func load(_ key: String) -> (data: Data, date: Date)? {
        let url = folder.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: url),
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        return (data, date)
    }

    /// The saved result no longer matches the disk (the app removed something itself): it stays
    /// as the last known result but counts as old, so the next launch checks it again.
    static func markStale(_ key: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-staleAfter - 60)],
                                                ofItemAtPath: folder.appendingPathComponent(key).path)
    }

    /// When a scan was last started, kept on disk so a scan that keeps failing (a scan folder
    /// that times out) is not walked again on every launch.
    static func lastAttempt(_ key: String) -> Date? { load(key + ".attempt")?.date }
    static func noteAttempt(_ key: String) { save(Data(), as: key + ".attempt") }

    static func isStale(_ date: Date?) -> Bool {
        date.map { Date().timeIntervalSince($0) > staleAfter } ?? true
    }
}

/// Runs a Mole dry run with pipes and keeps the parsed result. The run belongs to the app,
/// not to a page: leaving the page does not stop it, and the result is there on return.
@MainActor
final class Scan<Report>: ObservableObject {
    @Published private(set) var report: Report?
    /// The output parsed so far, while a scan is running.
    @Published private(set) var live: Report?
    @Published private(set) var scanning = false
    @Published private(set) var error: String?
    /// The section Mole is in and the line it printed last, for live progress.
    @Published private(set) var section = ""
    @Published private(set) var status = ""
    @Published private(set) var startedAt = Date()
    @Published private(set) var finishedAt: Date?
    var onBusyChange: ((Bool) -> Void)?

    private let args: [String]
    private let cacheKey: String

    private let parse: (String) -> Report
    /// Whether a run that exited 1 still printed a whole result (purge: "Dry run incomplete").
    private let usableAfterFailure: ((Report) -> Bool)?
    private let progressFile: URL?
    private var task: Task<Void, Never>?
    private var buffer = ""
    private var lastParse = Date.distantPast

    /// `progressFile` is a file Mole rewrites with the path it is scanning (read only).
    init(_ args: [String], progressFile: URL? = nil, usableAfterFailure: ((Report) -> Bool)? = nil,
         parse: @escaping (String) -> Report) {
        self.args = args
        self.progressFile = progressFile
        self.parse = parse
        self.usableAfterFailure = usableAfterFailure
        cacheKey = args.joined(separator: " ")
        // `-scanPreview 1`: every page looks mid-scan, for reviewing the scanning state; Mole never starts.
        scanning = UserDefaults.standard.bool(forKey: "scanPreview")
        if let saved = ResultCache.load(cacheKey) {
            report = parse(String(decoding: saved.data, as: UTF8.self))
            finishedAt = saved.date
        }
    }

    /// The newest result: the finished report, or what the running scan found so far.
    var current: Report? { scanning ? (live ?? report) : report }

    func startIfNeeded() { if report == nil, error == nil { start() } }

    func start() {
        guard task == nil else { return }
        ResultCache.noteAttempt(cacheKey)
        task = Task { await perform(); task = nil }
    }

    /// Scans again when there is no result yet or it is old; returns once the scan is done.
    func refreshIfStale() async {
        guard task != nil || (ResultCache.isStale(finishedAt) && ResultCache.isStale(ResultCache.lastAttempt(cacheKey))) else { return }
        start()
        await task?.value
    }

    /// Stops a running scan and keeps the previous result.
    func cancel() { task?.cancel() }

    /// Adjusts the last result after the app changed something itself (for example trashed items).
    func update(_ change: (inout Report) -> Void) {
        guard var r = report else { return }
        change(&r)
        report = r
        // The adjusted report cannot be saved as Mole's output; the next launch scans again.
        ResultCache.markStale(cacheKey)
    }

    private func perform() async {
        scanning = true
        error = nil
        live = nil
        section = ""
        status = ""
        buffer = ""
        startedAt = Date()
        onBusyChange?(true)
        let watcher = progressFile.map(watch)
        defer {
            watcher?.cancel()
            scanning = false
            onBusyChange?(false)
        }
        do {
            let data = try await Mole.capture(args) { [weak self] line in self?.ingest(line) }
            // Stopped after Mole finished but before this resumed: keep the previous result.
            guard !Task.isCancelled else { return }
            report = parse(String(decoding: data, as: UTF8.self))
            finishedAt = Date()
            ResultCache.save(data, as: cacheKey)
        } catch let failure as MoleError where failure.code == 1 && !Task.isCancelled {
            // Mole finished but could not check everything: keep what it found, its warnings included.
            let partial = parse(String(decoding: failure.output, as: UTF8.self))
            if usableAfterFailure?(partial) == true {
                report = partial
                finishedAt = Date()
                ResultCache.save(failure.output, as: cacheKey)
            } else {
                self.error = failure.localizedDescription
            }
        } catch {
            // A stopped scan is not an error; the last good result stays.
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func ingest(_ line: String) {
        buffer += line + "\n"
        let text = TerminalText.visible(line)
        if text.hasPrefix("➤") {
            section = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if progressFile == nil, let first = text.first, "→✓⊙◎".contains(first) {
            // With a progress file, that file alone says where Mole is (no flicker between two sources).
            status = Self.describe(text)
        }
        // Re-parsing the whole output is cheap but not free; a few times a second is plenty.
        if Date().timeIntervalSince(lastParse) > 0.35 {
            lastParse = Date()
            live = parse(buffer)
        }
    }

    private func watch(_ url: URL) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                let path = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty { self?.status = (path as NSString).abbreviatingWithTildeInPath }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// "→ User app cache · 38 items, 1.41GB dry" → "User app cache".
    nonisolated static func describe(_ line: String) -> String {
        let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "[DRY RUN] ", with: "")
        let name = body.components(separatedBy: " · ").first ?? body
        return name.components(separatedBy: ", ").first ?? name
    }
}

/// "Checked 5 minutes ago" that keeps itself current while the window sits idle.
struct CheckedAgo: View {
    let date: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            // Seconds would sit stale between minute ticks.
            Text(context.date.timeIntervalSince(date) < 60 ? "Checked just now"
                 : "Checked \(date.formatted(.relative(presentation: .named)))").caption()
        }
    }
}

/// The large hero card at the top of every tool page. While Mole scans it shows the total
/// found so far, the section Mole is in and how long it has been running.
struct HeroCard<Actions: View>: View {
    let glow: Glow
    let label: String
    let bytes: Int64?
    /// The figure is a lower bound (Mole could not size everything): shown as "GB+".
    var atLeast = false
    let detail: String
    var scanning = false
    var progress = ""
    var started = Date()
    /// When the result on screen was found; it may come from an earlier launch.
    var checked: Date?
    var error: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        GlowCard(glow: glow, style: .rim, padding: 26, busy: scanning) {
            VStack(alignment: .leading, spacing: 14) {
                // One fixed-height title row in every state, so the badge never pushes the value down.
                HStack {
                    Text(label).cardTitle()
                    Spacer()
                    if scanning {
                        ScanningBadge(started: started).transition(.blurFade)
                    } else if let checked {
                        CheckedAgo(date: checked).transition(.blurFade)
                    }
                }
                .frame(height: 28)
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        value.frame(minHeight: 84, alignment: .bottomLeading)
                        footnote
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 10) { actions }.fixedSize()
                }
            }
        }
        .frame(minHeight: 216)
        .fixedSize(horizontal: false, vertical: true)
        .animation(Motion.spring, value: scanning)
    }

    @ViewBuilder private var value: some View {
        if let error, !scanning {
            Label("Mole could not finish", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 24, weight: .semibold))
                .symbolRenderingMode(.multicolor)
                .help(error)
        } else if let bytes, !(scanning && bytes == 0) {
            MetricValue(value: bytes.metric.value, unit: bytes.metric.unit + (atLeast ? "+" : ""), dot: 7, live: scanning)
        } else if scanning {
            Text("Looking…").font(.system(size: 26, weight: .medium)).shimmer()
        } else {
            Text("Not scanned yet").font(.system(size: 26, weight: .medium))
        }
    }

    @ViewBuilder private var footnote: some View {
        if scanning {
            Text(progress.isEmpty ? "Mole is starting…" : progress)
                .caption().lineLimit(1).truncationMode(.middle)
                .contentTransition(.opacity)
                .animation(Motion.quick, value: progress)
        } else if let error {
            Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).lineLimit(2)
        } else {
            Text(detail).caption().lineLimit(2)
        }
    }
}

/// "Scanning 0:42" with a small spinner.
struct ScanningBadge: View {
    let started: Date

    var body: some View {
        HStack(spacing: 8) {
            PulseDot()
            Text("Scanning")
            Elapsed(since: started)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(Capsule().fill(.black.opacity(0.35)))
        .overlay(Pill().strokeBorder(.white.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }
}

/// Minutes and seconds since a moment, ticking once a second.
struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            Text(Duration.seconds(max(0, ctx.date.timeIntervalSince(since))).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
        }
    }
}

/// Sections of a dry run as cards in two columns.
struct SectionGrid: View {
    let sections: [ReportSection]
    var glow: Glow = .graphite
    /// Lines Mole words as if already done ("DNS cache refreshed") get hollow bullets: not yet.
    var preview = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 18, alignment: .top), GridItem(.flexible(), spacing: 18, alignment: .top)],
                  alignment: .leading, spacing: 18) {
            ForEach(sections) { section in
                GlowCard(glow: glow, style: .plain, padding: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(section.title).cardTitle()
                            Spacer()
                            if section.bytes > 0 {
                                Text(section.bytes.bytesText).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            }
                        }
                        ForEach(section.items) { item in ReportRow(item: item, preview: preview) }
                    }
                }
                .transition(.blurFade)
            }
        }
        .animation(Motion.spring, value: sections.count)
    }
}

struct ReportRow: View {
    let item: ReportItem
    var preview = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if preview && item.kind == .action {
                    Circle().strokeBorder(dotColor, lineWidth: 1.3)
                } else {
                    Circle().fill(dotColor)
                }
            }
            .frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13)).foregroundStyle(item.kind == .ok ? Theme.secondaryText : .white)
                if !cleanDetail.isEmpty {
                    Text(cleanDetail).font(.system(size: 11.5)).foregroundStyle(Theme.tertiaryText).lineLimit(2)
                }
            }
            Spacer()
            switch item.kind {
            case .action:
                if let b = item.bytes, b > 0 { Text(b.bytesText).font(.system(size: 12.5)).monospacedDigit() }
            case .info: Tag(text: "Manual", color: Glow.blue.color).help("Mole lists this but leaves it to you")
            case .skipped where needsDiskAccess:
                Button("Open Settings") { NSWorkspace.shared.open(Self.fullDiskAccess) }
                    .buttonStyle(.link).font(.system(size: 12, weight: .medium))
                    .help("Privacy & Security → Full Disk Access: turn on Burrow, then scan again")
            case .skipped: Tag(text: "Skipped", color: .orange)
            case .ok: EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    private var needsDiskAccess: Bool { item.detail.contains("Full Disk Access") }

    private var dotColor: Color {
        switch item.kind {
        case .action: Theme.accent
        case .info: Glow.blue.color
        case .skipped: .orange
        case .ok: .white.opacity(0.25)
        }
    }

    /// The size is already shown on the right; keep the rest of Mole's detail.
    private var cleanDetail: String {
        // Mole speaks to terminal users; here the app is the one that needs the access.
        var detail = item.detail.replacingOccurrences(of: "to your terminal", with: "to Burrow")
        // "skipped, grant…": the tag on the right already says skipped.
        if item.kind == .skipped, detail.hasPrefix("skipped, ") {
            detail = String(detail.dropFirst("skipped, ".count))
            detail = detail.prefix(1).uppercased() + detail.dropFirst()
        }
        guard item.kind == .action, let b = item.bytes, b > 0 else { return detail }
        return detail.components(separatedBy: ", ").filter { ByteSize.first(in: $0) == nil }.joined(separator: ", ")
    }
}

struct Notes: View {
    let notes: [String]

    var body: some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }
}

/// A calm placeholder for empty, loading and failed states, with an optional action.
struct EmptyState: View {
    let symbol: String
    let text: String
    var detail: String = ""
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light))
                .symbolEffect(.pulse, options: .repeating, isActive: symbol == "hourglass" && !Motion.reduced)
            Text(text).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            if !detail.isEmpty {
                Text(detail).font(.system(size: 12)).frame(maxWidth: 420).lineLimit(3)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.pillSecondary).padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(Theme.secondaryText)
        .frame(maxWidth: .infinity, minHeight: 220)
        .transition(.blurFade)
    }
}

/// A checkbox that matches the dark cards. The row that owns it carries the accessibility.
struct CheckDot: View {
    let on: Bool
    var tint: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(on ? 0 : 0.3), lineWidth: 1.5)
            Circle().fill(tint).scaleEffect(on ? 1 : 0.4).opacity(on ? 1 : 0)
            Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.black)
                .scaleEffect(on ? 1 : 0.5).opacity(on ? 1 : 0)
        }
        .frame(width: 18, height: 18)
        .animation(Motion.quick, value: on)
        .accessibilityHidden(true)
    }
}

/// A selectable tile for grids of apps and files: icon and text on the left, a check on the right.
struct SelectTile<Content: View>: View {
    let selected: Bool
    var glow: Glow = .ember
    let toggle: () -> Void
    @ViewBuilder var content: Content
    @ViewState private var hover = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                // One flexible region, so a trailing column inside `content` lines up across tiles.
                HStack(spacing: 12) { content }.frame(maxWidth: .infinity, alignment: .leading)
                CheckDot(on: selected)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(selected ? glow.color.opacity(0.22) : .white.opacity(hover ? 0.08 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(selected ? glow.color.opacity(0.75) : Theme.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverLift(1.02)
        .onHover { hover = $0 }
        .animation(Motion.quick, value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Floating selection bar

/// A bar that floats over the bottom of the window while something is selected.
struct BottomBar {
    let view: AnyView
}

struct BottomBarKey: PreferenceKey {
    static let defaultValue: BottomBar? = nil
    static func reduce(value: inout BottomBar?, nextValue: () -> BottomBar?) { value = nextValue() ?? value }
}

/// The content of the floating bar: what is selected, a way to clear it, and the actions.
struct SelectionBar<Actions: View>: View {
    let glow: Glow
    let title: String
    var subtitle: String = ""
    let clear: () -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 14) {
            Button(action: clear) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28).background(Circle().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Clear selection (Esc)")
            .accessibilityLabel("Clear selection")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                if !subtitle.isEmpty { Text(subtitle).caption().lineLimit(1) }
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 16)
        .frame(height: 68)
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color(white: 0.06).opacity(0.75))
                Capsule().fill(RadialGradient(colors: [glow.color.opacity(0.55), .clear], center: .trailing,
                                              startRadius: 0, endRadius: 420))
            }
        }
        .overlay(Pill().strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .shadow(color: glow.color.opacity(0.25), radius: 30, y: 6)
        .animation(Motion.quick, value: title)
    }
}

extension View {
    /// Shows `bar` floating at the bottom of the window while `shown` is true.
    func bottomBar<Bar: View>(_ shown: Bool, @ViewBuilder bar: () -> Bar) -> some View {
        padding(.bottom, shown ? 84 : 0)
            .preference(key: BottomBarKey.self, value: shown ? BottomBar(view: AnyView(bar())) : nil)
    }
}

// MARK: - Confirmation

/// Asks before a destructive step, in the app's words.
struct ConfirmAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let button: String
    let action: () -> Void
}

extension View {
    func confirmation(_ item: Binding<ConfirmAction?>) -> some View {
        alert(item.wrappedValue?.title ?? "", isPresented: Binding(get: { item.wrappedValue != nil },
                                                                     set: { if !$0 { item.wrappedValue = nil } })) {
            Button(item.wrappedValue?.button ?? "OK", role: .destructive) { item.wrappedValue?.action() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(item.wrappedValue?.message ?? "")
        }
    }
}

/// Moves files to the Trash and returns the paths that could not be moved.
enum Trash {
    static func move(_ paths: [String]) -> [String] {
        paths.filter { path in
            (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) == nil
        }
    }
}
