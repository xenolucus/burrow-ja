import Sparkle
import SwiftUI

@main
struct BurrowApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = AppModel()
    @AppStorage("showInMenuBar") private var showInMenuBar = true

    var body: some Scene {
        // One window: reopening it from the menu bar brings back the same one.
        Window("Burrow", id: "main") {
            RootView()
                .environmentObject(model)
                .onAppear {
                    delegate.model = model
                    let defaults = UserDefaults.standard
                    if let folder = defaults.string(forKey: "tour") { Tour.start(model, into: folder) }
                    if let file = defaults.string(forKey: "replayRun"), let text = try? String(contentsOfFile: file, encoding: .utf8) {
                        model.replay(defaults.string(forKey: "replayTitle") ?? "Slimming apps", transcript: text,
                                     plan: Int64(defaults.string(forKey: "replayPlan") ?? ""))
                    }
                }
                .frame(minWidth: 1080, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { delegate.updater?.checkForUpdates(nil) }
            }
            CommandMenu("Go") {
                ForEach(Page.allCases) { page in
                    Button(page.title) { model.page = page }
                        .keyboardShortcut(page.shortcut, modifiers: .command)
                }
            }
        }

        MenuBarExtra(isInserted: $showInMenuBar) {
            TrayView(model: model, monitor: model.status, leftovers: model.leftovers)
        } label: {
            Image(nsImage: TrayIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

extension NSApplication {
    /// The main window, not the menu bar card, a run sheet or the leftovers panel.
    var burrowWindow: NSWindow? { windows.first { $0.identifier?.rawValue.hasPrefix("main") == true } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    /// Set by the app once its model exists, so quitting can see a running session.
    weak var model: AppModel?
    /// Sparkle, reading the appcast on the GitHub releases. Only in a bundle that names a feed,
    /// and never in review snapshots or the demo tour.
    private(set) var updater: SPUStandardUpdaterController?
    private var trayHost: NSWindow?

    override init() {
        // Burrow keeps running with its window closed, and the saved "no windows" state would
        // start the next launch with no window at all.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "showInMenuBar": true])
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from `swift run` the binary is not an app bundle yet; make it a normal app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // `kill` or a logout skips applicationWillTerminate; stop Mole's processes then too.
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            // A do-nothing handler, not SIG_IGN: an ignored signal is inherited by every Mole
            // process Burrow starts, while a handled one is reset to the default on exec.
            signal(sig) { _ in }
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Mole.terminateAll()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
        scheduleSnapshot()
        let defaults = UserDefaults.standard
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil, !AppModel.reviewMode {
            updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        // Opened at login only to watch for deleted apps: no window until the user asks.
        let event = NSAppleEventManager.shared().currentAppleEvent
        if RemovalWatcher.enabled, event?.eventID == kAEOpenApplication,
           event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            DispatchQueue.main.async { NSApp.burrowWindow?.close() }
        }
    }

    /// `-snapshot <file.png> [-snapshotDelay <seconds>]`: draws the window into a PNG without the
    /// screen (works while the Mac is locked), then quits. Used for screenshots in reviews.
    private func scheduleSnapshot() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "snapshot") else { return }
        if defaults.bool(forKey: "snapshotTray") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let model = self.model else { return }
                let host = NSHostingView(rootView: TrayView(model: model, monitor: model.status, leftovers: model.leftovers))
                host.frame.size = host.fittingSize
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                window.orderFrontRegardless()
                self.trayHost = window
            }
        }
        let delay = defaults.double(forKey: "snapshotDelay") > 0 ? defaults.double(forKey: "snapshotDelay") : 10
        // `-snapshotSize 1080x700` checks a layout at a given window size.
        if let size = defaults.string(forKey: "snapshotSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.burrowWindow?.setContentSize(NSSize(width: size[0], height: size[1]))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // `-snapshotTray 1` draws the menu bar card instead of the window.
            if defaults.bool(forKey: "snapshotTray"), let host = self.trayHost?.contentView {
                host.setFrameSize(host.fittingSize)
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                Mole.terminateAll()
                exit(0)
            }
            // An open run sheet is drawn instead of the window behind it.
            let window = NSApp.burrowWindow
            if let view = (window?.attachedSheet ?? window)?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            // Not terminate: an open run sheet can hold it up, and nothing here needs saving.
            Mole.terminateAll()
            exit(0)
        }
    }

    /// A real Mole run (the run sheet) is not stopped silently: ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session = MainActor.assumeIsolated({ model?.session }), !session.isFinished, session.runsMole else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Mole is still working"
        alert.informativeText = "“\(session.title)” has not finished. Quitting stops it where it is."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Stop and Quit")
        alert.buttons[1].hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) { Mole.terminateAll() }

    /// While it sits in the menu bar or offers to clean up after deleted apps, Burrow keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !RemovalWatcher.enabled && !UserDefaults.standard.bool(forKey: "showInMenuBar")
    }
}
