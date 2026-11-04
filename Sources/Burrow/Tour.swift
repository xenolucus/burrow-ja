import SwiftUI

/// `-tour <folder>`: walks through every page the way a person would, then quits. The window is
/// placed at a fixed size and its screen rectangle (top-left origin, points) is written to
/// `<folder>/rect` so `scripts/demo-video.sh` can screen-record exactly it; the steps start a
/// moment later. It only navigates and replays a recorded run: it never starts a Mole action or a scan.
@MainActor
enum Tour {
    private static let steps: [(seconds: Double, step: @MainActor (AppModel) -> Void)] = [
        (3.5, { $0.page = .overview }),
        (3.5, { $0.page = .clean }),
        (3, { $0.page = .uninstall }),
        (3, { _ in UserDefaults.standard.set(true, forKey: "uninstall.showLeftovers") }),
        (2, { _ in UserDefaults.standard.set(false, forKey: "uninstall.showLeftovers") }),
        (3, { $0.page = .optimize }),
        (3.5, { $0.page = .analyze }),
        (3, { $0.page = .projects }),
        (3, { $0.page = .installers }),
        (2.5, { $0.page = .slim }),
        // A recorded slim run in the run sheet: Mole never starts.
        (7, { $0.replay("Slimming apps", transcript: slimRun, plan: 886_800_000, pace: 0.33) }),
        (1, { $0.closeSession() }),
        (3, { $0.page = .history }),
        (3, { $0.page = .settings }),
        (3, { $0.page = .overview }),
    ]

    private static let slimRun = """
        Apps to slim:
        ◎ Google Chrome, 576.3MB
        ◎ Slack, 212.4MB
        ◎ Zoom, 98.1MB
        ⠋ [1/3] Slimming Google Chrome...\\r
        ⠙ [1/3] Slimming Google Chrome...\\r
        \\r✓ [1/3] Google Chrome, 576.3MB
        ⠹ [2/3] Slimming Slack...\\r
        ⠸ [2/3] Slimming Slack...\\r
        \\r✓ [2/3] Slack, 212.4MB
        ⠼ [3/3] Slimming Zoom...\\r
        ⠴ [3/3] Slimming Zoom...\\r
        \\r✓ [3/3] Zoom, 98.1MB
        Slimmed 3 apps, freed 886.8MB: Google Chrome, Slack, Zoom
        """

    static func start(_ model: AppModel, into folder: String, waited: Double = 0) {
        guard let window = NSApp.burrowWindow, let screen = NSScreen.screens.first else { return }
        // Start once the live status and the leftovers are on hand, so no page shows a placeholder.
        let ready = model.status.status != nil && model.leftovers.leftovers != nil
        if !ready, waited < 60 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { start(model, into: folder, waited: waited + 0.25) }
            }
            return
        }
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
        let f = window.frame
        let rect = "\(Int(f.minX)),\(Int(screen.frame.maxY - f.maxY)),\(Int(f.width)),\(Int(f.height))"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? rect.write(toFile: (folder as NSString).appendingPathComponent("rect"), atomically: true, encoding: .utf8)

        // The recorder starts once it reads the rectangle.
        var at = 2.0
        for (seconds, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { MainActor.assumeIsolated { step(model) } }
            at += seconds
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + at) { NSApp.terminate(nil) }
    }
}
