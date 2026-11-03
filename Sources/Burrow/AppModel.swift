import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case overview, clean, uninstall, optimize, analyze, projects, installers, slim, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .clean: "Clean"
        case .uninstall: "Uninstall"
        case .optimize: "Optimize"
        case .analyze: "Disk Map"
        case .projects: "Projects"
        case .installers: "Installers"
        case .slim: "Slim Apps"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "circle.hexagongrid"
        case .clean: "sparkles"
        case .uninstall: "trash"
        case .optimize: "bolt"
        case .analyze: "square.grid.3x3.square"
        case .projects: "shippingbox"
        case .installers: "opticaldiscdrive"
        case .slim: "scissors"
        case .history: "clock.arrow.circlepath"
        case .settings: "slider.horizontal.3"
        }
    }

    var glow: Glow {
        switch self {
        case .overview, .history: .violet
        case .clean, .slim: .magenta
        case .uninstall, .installers: .ember
        case .optimize, .settings: .sage
        case .analyze, .projects: .blue
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "Live health of this Mac"
        case .clean: "Caches, logs and leftovers of removed apps"
        case .uninstall: "Remove apps with everything they left behind"
        case .optimize: "Refresh system caches and services"
        case .analyze: "See what takes the space"
        case .projects: "Build folders of projects you are not touching"
        case .installers: "Disk images and packages you no longer need"
        case .slim: "Drop the Intel half of universal apps"
        case .history: "Everything Mole changed, newest first"
        case .settings: "Protection rules, scan folders, Touch ID, deleted apps"
        }
    }

    var shortcut: KeyEquivalent {
        let keys: [Page: Character] = [.overview: "1", .clean: "2", .uninstall: "3", .optimize: "4", .analyze: "5",
                                       .projects: "6", .installers: "7", .slim: "8", .history: "9", .settings: ","]
        return KeyEquivalent(keys[self] ?? "0")
    }
}

/// Shared state: navigation, the running Mole session and the last scan of each tool.
@MainActor
final class AppModel: ObservableObject {
    /// `-startPage clean` on the command line opens a page directly (handy for screenshots).
    @Published var page = Page(rawValue: UserDefaults.standard.string(forKey: "startPage") ?? "") ?? .overview
    @Published var session: MoleSession?
    /// Pages with work in progress, marked in the sidebar.
    @Published private(set) var busy = Set<Page>()

    let clean = Scan(["clean", "--dry-run"], parse: SectionReport.parse)
    let optimize = Scan(["optimize", "--dry-run"], parse: SectionReport.parse)
    /// Mole rewrites this file with the folder it is scanning; Burrow only reads it.
    let purge = Scan(["purge", "--dry-run"],
                     progressFile: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/mole/purge_scanning"),
                     usableAfterFailure: { $0.complete }, parse: PurgeReport.parse)
    let slim = Scan(["slim", "--dry-run"], parse: SlimReport.parse)
    let apps = AppCatalog()
    let diskMap = DiskMap()
    let installers = InstallerStore()
    let leftovers = LeftoverStore()
    /// Offers the leftovers of an app the moment it is deleted.
    private(set) lazy var removals = RemovalWatcher(store: leftovers)
    /// Lives here, not on the page, so the last numbers are on screen at once on every visit.
    let status = StatusMonitor()

    init() {
        clean.onBusyChange = { [weak self] in self?.mark(.clean, $0) }
        optimize.onBusyChange = { [weak self] in self?.mark(.optimize, $0) }
        purge.onBusyChange = { [weak self] in self?.mark(.projects, $0) }
        slim.onBusyChange = { [weak self] in self?.mark(.slim, $0) }
        installers.onBusyChange = { [weak self] in self?.mark(.installers, $0) }
        leftovers.onBusyChange = { [weak self] in self?.mark(.uninstall, $0) }
        diskMap.onBusyChange = { [weak self] in self?.mark(.analyze, $0) }
        Task {
            await installers.load()
            await leftovers.load()
            await refreshStale()
        }
        if !Self.reviewMode {
            removals.start()
        }
        // A window left open for days still gets fresh results when the user comes back to it.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refreshStale() } }
        }
    }

    private var refreshing = false

    /// Review snapshots, the demo tour and replayed runs show what is cached; they never start Mole.
    nonisolated static var reviewMode: Bool {
        ["snapshot", "tour", "replayRun", "scanPreview"].contains { UserDefaults.standard.string(forKey: $0) != nil }
    }

    /// Last results come from the cache at once. In the background, one at a time so the Mac
    /// stays responsive, anything missing or older than a few hours is checked again: quick
    /// scans first, the slow walks (Disk Map, project folders) last. Pages never re-scan on
    /// their own; the Rescan buttons do.
    func refreshStale() async {
        guard !refreshing, !Self.reviewMode else { return }
        refreshing = true
        defer { refreshing = false }
        await leftovers.refreshIfAppsChanged()
        await optimize.refreshIfStale()
        await slim.refreshIfStale()
        await apps.refreshIfStale()
        await clean.refreshIfStale()
        await diskMap.refreshIfStale()
        await purge.refreshIfStale()
    }

    private func mark(_ page: Page, _ on: Bool) {
        if on { busy.insert(page) } else { busy.remove(page) }
    }

    /// Starts a Mole command in the run sheet. `onFinish` runs after the user closes the sheet.
    func run(_ title: String, _ args: [String], plan: Int64? = nil, responders: [MoleSession.Responder] = [],
             onFinish: (() -> Void)? = nil) {
        guard session == nil else { return }
        let s = MoleSession(title: title, args: args, plan: plan, responders: responders)
        finishHandler = onFinish
        session = s
        s.start()
    }

    /// `-replayRun <transcript>`: the run sheet plays a recorded Mole run; Mole never starts.
    func replay(_ title: String, transcript: String, plan: Int64?, pace: Double = 0.45) {
        guard session == nil else { return }
        let s = MoleSession(title: title, args: [], plan: plan)
        session = s
        s.replay(transcript, pace: pace)
    }

    private var finishHandler: (() -> Void)?

    /// Closes the run sheet; `sessionDismissed` follows once it is gone.
    func closeSession() { session = nil }

    /// Runs once the sheet is gone, however it was closed.
    func sessionDismissed() {
        let handler = finishHandler
        finishHandler = nil
        handler?()
    }
}
