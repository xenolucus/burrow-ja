import Foundation
import Testing
@testable import Burrow

struct ParserTests {
    @Test func cleanDryRun() {
        let out = """
        \u{1B}[1;35mClean Your Mac\u{1B}[0m
        ◎ System caches need sudo, run sudo -v && mo clean --dry-run for full preview
        ✓ Whitelist: 8 core + 1 custom patterns active
          ↳ /Users/x/Library/Caches/kitty
        ➤ User essentials
          → User app cache · 36 items, 1.30GB dry
          ◎ Trash · skipped, grant Full Disk Access to your terminal
        ➤ Cloud & Office
          ✓ Nothing to clean
        ➤ Large files
          ⊙ pnpm store · 2.78GB · ~/Library/pnpm/store
        ======================================================================
        Dry run complete - no changes made
        Potential space: 10.63GB+ | Items: 524 | Categories: 6
        ======================================================================
        """
        let r = SectionReport.parse(out)
        #expect(r.sections.map(\.title) == ["User essentials", "Cloud & Office", "Large files"])
        #expect(r.sections[0].items[0].name == "User app cache")
        #expect(r.sections[0].items[0].bytes == 1_300_000_000)
        #expect(r.sections[0].items[1].kind == .skipped)
        #expect(r.sections[2].items[0].kind == .info)
        #expect(r.bytes == 1_300_000_000) // manual items are not counted
        #expect(r.notes.count == 1)
        #expect(r.summary.count == 2)
        #expect(r.potential == 10_630_000_000 && r.potentialIsLowerBound)
        #expect(r.total == 10_630_000_000)
        #expect(r.itemCount == 524 && r.categoryCount == 6)
    }

    @Test func purgeAndSlim() {
        let purge = PurgeReport.parse("✓ [DRY RUN] ~/PROJECTS/A/node_modules, 1.5GB\n\r✓ [DRY RUN] ~/PROJECTS/A/apps/web/.next, 20MB\nWould free approximately: 1.52GB | Items: 2")
        #expect(purge.artifacts.count == 2)
        #expect(purge.artifacts[1].project == ("~/PROJECTS/A/apps/web" as NSString).expandingTildeInPath)
        #expect(purge.artifacts[0].project == ("~/PROJECTS/A" as NSString).expandingTildeInPath)
        let slim = SlimReport.parse("→ DRY RUN MODE\n\n  Google Chrome        576.3MB\n  Arc                  350.8MB\n\n2 apps, 927.1MB of Intel code")
        #expect(slim.apps.map(\.name) == ["Google Chrome", "Arc"])
        #expect(slim.bytes == 927_100_000)
    }

    @Test func terminalText() {
        #expect(TerminalText.visible("⠋ Scanning\r\u{1B}[2K✓ Done") == "✓ Done")
        #expect(MoleSession.completeUTF8Length(Data("ab".utf8) + Data([0xE2, 0x9C])) == 2)
        #expect(MoleSession.completeUTF8Length(Data("a✓".utf8)) == 4)
        #expect(TerminalText.lines("one\r\ntwo\r\n⠋ x\r✓ three") == ["one", "two", "✓ three"])
    }

    @Test func treemapFillsRect() {
        let rects = Treemap.layout([6, 6, 4, 3, 2, 2, 1], in: CGRect(x: 0, y: 0, width: 600, height: 400))
        let area = rects.map { $0.width * $0.height }.reduce(0, +)
        #expect(abs(area - 240_000) < 1)
    }

    @Test func installerNames() {
        #expect(InstallerScanner.isInstaller("Claude.dmg"))
        #expect(InstallerScanner.isInstaller("BssPluginSetup.app.zip"))
        #expect(!InstallerScanner.isInstaller("photos.zip"))
    }
}

struct BehaviourTests {
    @Test func zeroBytesStayNumeric() {
        #expect(Int64(0).metric.value.allSatisfy { $0.isNumber || $0 == "." || $0 == "," })
        #expect(ByteSize.format(0).contains("0"))
        #expect(ByteSize.format(11_270_000_000) == "11.27 GB")
    }

    @Test func reportIdsSurviveReparse() {
        let partial = "➤ User essentials\n  → User app cache · 36 items, 1.30GB dry\n"
        let full = partial + "  → User app logs · 3 items, 3.7MB dry\n➤ Browsers\n  → Chrome cache · 11.1MB dry\n"
        let a = SectionReport.parse(partial), b = SectionReport.parse(full)
        #expect(a.sections[0].id == b.sections[0].id)
        #expect(a.sections[0].items[0].id == b.sections[0].items[0].id)
        #expect(Set(b.sections.flatMap(\.items).map(\.id)).count == 3)
    }

    @Test func scanStatusLine() {
        #expect(Scan<SectionReport>.describe("→ User app cache · 38 items, 1.41GB dry") == "User app cache")
        #expect(Scan<SectionReport>.describe("→ Arc Service Worker, would clean 40.1MB, 0 protected") == "Arc Service Worker")
        #expect(Scan<PurgeReport>.describe("✓ [DRY RUN] ~/P/a/.expo, 4KB") == "~/P/a/.expo")
    }

    @Test func purgeNotes() {
        let r = PurgeReport.parse("◎ Skipped 1 project scan root because scanning did not complete:\n  ~/P (status 124)\n✓ [DRY RUN] ~/P/a/node_modules, 1GB")
        #expect(r.notes == ["Skipped 1 project scan root because scanning did not complete: ~/P"])
        #expect(r.skippedRoots == ["~/P"])
        #expect(r.artifacts.count == 1)
    }

    @Test func appSizeFromMole() throws {
        let json = #"[{"name":"Steam","bundle_id":"com.valvesoftware.steam","source":"App","uninstall_name":"Steam","path":"/Applications/Steam.app","size":"11.3MB"}]"#
        let apps = try JSONDecoder().decode([InstalledApp].self, from: Data(json.utf8))
        #expect(apps[0].bytes == 11_300_000)
    }

    @Test func historyHidesPreviews() throws {
        let json = #"{"sessions":[{"command":"clean-dry-run","started_at":"2026-10-30 03:20:08","items":9,"size":"1GB"},{"command":"uninstall","started_at":"2026-10-30 03:20:06","items":0,"size":"0B","actions":{"removed":0}},{"command":"clean","started_at":"2026-10-29 10:00:00","items":12,"size":"2GB"}]}"#
        let h = try JSONDecoder().decode(HistoryResult.self, from: Data(json.utf8))
        #expect(h.sessions?.filter(\.changedSomething).map(\.command) == ["clean"])
        #expect(h.sessions?[0].title == "Clean")
    }

    @Test func quickRepliesForMolePrompts() {
        let sudo = QuickReply.options(for: "→ System caches need sudo. Enter continue, Space skip:")
        #expect(sudo.map(\.label) == ["Continue", "Skip"])
        #expect(sudo[0].keys == "\r" && sudo[1].keys == " ")
        let purge = QuickReply.options(for: "→ Remove 3 artifacts, 1.2GB  Enter confirm, ESC cancel:")
        #expect(purge.map(\.label) == ["Remove", "Cancel"])
    }

    /// Runs the bundled Mole; only harmless invocations (version, a rejected flag).
    @Test func captureStreamsAndReportsFailure() async throws {
        var seen: [String] = []
        let data = try await Mole.capture(["--version"]) { seen.append($0) }
        #expect(String(decoding: data, as: UTF8.self).contains("Mole version"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen.contains { $0.contains("Mole version") })
        await #expect(throws: MoleError.self) { _ = try await Mole.capture(["purge", "--no-such-flag"]) }
    }
}

/// Drives real Mole sessions in a pseudo-terminal, with harmless commands only.
@MainActor
struct SessionTests {
    private func waitUntil(_ session: MoleSession, seconds: Double, _ done: (MoleSession) -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(session), Date() < end { try? await Task.sleep(for: .milliseconds(200)) }
    }

    @Test func touchIDStatusRunsInTerminal() async {
        let s = MoleSession(title: "Touch ID", args: ["touchid", "status"])
        s.start()
        await waitUntil(s, seconds: 20) { $0.isFinished }
        #expect(s.exitCode == 0)
        #expect(s.lines.contains { $0.contains("Touch ID") })
    }

    /// Even when the app ignores INT/TERM/HUP, Mole must get default signals so Stop runs its
    /// cleanup traps and exits on SIGINT, well before the SIGKILL fallback (137) at 4 s.
    @Test func stopReachesMoleTrapsEvenIfTheAppIgnoresSignals() async {
        for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig, SIG_IGN) }
        defer { for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig, SIG_DFL) } }
        let s = MoleSession(title: "Preview", args: ["uninstall", "--dry-run", "Steam"])
        s.start()
        try? await Task.sleep(for: .seconds(1.5))
        let stopped = Date()
        s.cancel()
        await waitUntil(s, seconds: 6) { $0.isFinished }
        #expect(s.isFinished)
        #expect(Date().timeIntervalSince(stopped) < 3)
        #expect(s.exitCode != 137)
    }

    /// Slow (Mole scans the app's files): BURROW_SLOW_TESTS=1 swift test --filter uninstallPreview
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BURROW_SLOW_TESTS"] != nil))
    func uninstallPreviewAsksAndCancels() async {
        let s = MoleSession(title: "Preview", args: ["uninstall", "--dry-run", "Steam"])
        s.start()
        await waitUntil(s, seconds: 240) { if case .needsAnswer = $0.phase { return true }; return $0.isFinished }
        print("PHASE:", s.phase)
        print(s.lines.suffix(40).joined(separator: "\n"))
        #expect(s.lines.contains { $0.contains("Steam.app") })
        if case .needsAnswer(let q) = s.phase {
            #expect(!q.contains("\n"))
            #expect(QuickReply.options(for: q).map(\.label) == ["Confirm", "Cancel"])
            s.cancel()
        }
        await waitUntil(s, seconds: 20) { $0.isFinished }
        #expect(s.isFinished)
    }

    /// Quitting Burrow must not leave Mole waiting at a prompt (Mole traps TERM and HUP).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BURROW_SLOW_TESTS"] != nil))
    func quittingStopsASessionAtAPrompt() async {
        let s = MoleSession(title: "Preview", args: ["uninstall", "--dry-run", "Steam"])
        s.start()
        await waitUntil(s, seconds: 240) { if case .needsAnswer = $0.phase { return true }; return $0.isFinished }
        Mole.terminateAll()
        await waitUntil(s, seconds: 10) { $0.isFinished }
        #expect(s.isFinished)
    }
}

struct TrashPolicyTests {
    let home = "/Users/me"

    @Test func neverOnTheWholeMacTour() {
        #expect(!TrashPolicy.allows("/Users/me/Downloads", inside: nil, home: home))
        #expect(!TrashPolicy.allows("/Users/me/Library", inside: nil, home: home))
    }

    @Test func neverTopLevelOrSystemFolders() {
        #expect(!TrashPolicy.allows("/Users/me/Downloads", inside: "/Users/me", home: home))
        #expect(!TrashPolicy.allows("/Users/me/Projects", inside: "/Users/me", home: home))
        #expect(!TrashPolicy.allows("/Users/me/Library/Caches", inside: "/Users/me/Library", home: home))
        #expect(!TrashPolicy.allows("/Users/me/.ssh/id_ed25519", inside: "/Users/me/.ssh", home: home))
        #expect(!TrashPolicy.allows("/Applications/Arc.app", inside: "/Applications", home: home))
        // Two levels into ~/Library: personal data and sync roots stay off limits.
        for (path, folder) in [("Keychains/login.keychain-db", "Keychains"),
                               ("Mobile Documents/com~apple~CloudDocs", "Mobile Documents"),
                               ("CloudStorage/GoogleDrive-me", "CloudStorage"), ("Mail/V10", "Mail"),
                               ("Messages/chat.db", "Messages"), ("Containers/com.apple.mail", "Containers"),
                               ("Group Containers/group.com.apple.notes", "Group Containers"),
                               ("Accounts/Accounts4.sqlite", "Accounts"), ("Preferences/com.foo.plist", "Preferences")] {
            #expect(!TrashPolicy.allows("/Users/me/Library/" + path, inside: "/Users/me/Library/" + folder, home: home), "\(path)")
        }
        #expect(!TrashPolicy.allows("/Users/me/Library/Application Support/MobileSync/Mail", inside: "/Users/me/Library/Application Support/MobileSync", home: home))
        // Personal data and sync state in Application Support, and Apple's own folders there.
        let support = "/Users/me/Library/Application Support"
        for name in ["AddressBook", "FileProvider", "MobileSync", "CallHistoryDB", "Knowledge", "com.apple.sharedfilelist"] {
            #expect(!TrashPolicy.allows(support + "/" + name, inside: support, home: home), "\(name)")
        }
        #expect(!TrashPolicy.allows(support + "/MobileSync/Backup", inside: support + "/MobileSync", home: home))
    }

    @Test func onlyDirectChildrenOfTheMappedFolder() {
        #expect(TrashPolicy.allows("/Users/me/Downloads/big.dmg", inside: "/Users/me/Downloads", home: home))
        #expect(TrashPolicy.allows("/Users/me/Library/Caches/com.foo", inside: "/Users/me/Library/Caches", home: home))
        #expect(TrashPolicy.allows("/Users/me/Library/Application Support/OldApp", inside: "/Users/me/Library/Application Support", home: home))
        #expect(TrashPolicy.allows("/Users/me/Library/Logs/OldApp", inside: "/Users/me/Library/Logs", home: home))
        #expect(!TrashPolicy.allows("/Users/me/Downloads", inside: "/Users/me/Downloads", home: home))
        #expect(!TrashPolicy.allows("/Users/me/Downloads/a/b", inside: "/Users/me/Downloads", home: home))
        #expect(!TrashPolicy.allows("/Users/me/Downloads/../Documents/x", inside: "/Users/me/Downloads", home: home))
    }
}

struct SettingsTests {
    @Test func homeSpellings() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for entry in ["~", "~/", "$HOME", "${HOME}/", home, home + "/", home + "/."] {
            #expect(ConfigList.isHome(entry), "\(entry)")
        }
        #expect(!ConfigList.isHome("~/PROJECTS"))
    }

    @Test func runningRunIsNotInterrupted() throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = f.string(from: Date()), old = f.string(from: Date().addingTimeInterval(-7200))
        let json = #"{"sessions":[{"command":"clean","started_at":"\#(now)","ended_at":""},{"command":"clean","started_at":"\#(old)","ended_at":""}]}"#
        let s = try JSONDecoder().decode(HistoryResult.self, from: Data(json.utf8)).sessions ?? []
        #expect(!s[0].looksInterrupted)
        #expect(s[1].looksInterrupted)
    }
}

struct LeftoverTests {
    @Test func bundleIDsFromLibraryNames() {
        #expect(LeftoverScanner.bundleID(fromEntry: "com.tinyspeck.slackmacgap") == "com.tinyspeck.slackmacgap")
        #expect(LeftoverScanner.bundleID(fromEntry: "com.foo.Bar.savedState") == "com.foo.Bar")
        #expect(LeftoverScanner.bundleID(fromEntry: "com.foo.Bar.plist") == "com.foo.Bar")
        #expect(LeftoverScanner.bundleID(fromEntry: "Slack") == nil)
        #expect(LeftoverScanner.bundleID(fromEntry: "com.foo") == nil)
        #expect(LeftoverScanner.bundleID(fromEntry: "Google.Chrome.x") == nil)
        #expect(LeftoverScanner.bundleID(fromEntry: "com.foo..bar") == nil)
        #expect(LeftoverScanner.bundleID(fromEntry: "com.foo bar.baz") == nil)
    }

    @Test func installedVendorsAndProtectedNamesStay() {
        let installed: Set<String> = ["com.google.chrome", "com.tinyspeck.slackmacgap"]
        #expect(LeftoverScanner.inUse("com.tinyspeck.slackmacgap", installed: installed))
        #expect(LeftoverScanner.inUse("com.google.Keystone.Agent", installed: installed))
        #expect(LeftoverScanner.inUse("com.apple.Safari", installed: []))
        #expect(LeftoverScanner.inUse("com.agilebits.onepassword7", installed: []))
        #expect(!LeftoverScanner.inUse("com.spotify.client", installed: installed))
        // A vendor prefix must match whole parts: com.googlex is not Google.
        #expect(!LeftoverScanner.inUse("com.googlex.app", installed: installed))
    }

    @Test func readableNames() {
        #expect(Leftover.displayName("com.figma.Desktop") == "Figma Desktop")
        #expect(Leftover.displayName("com.netease.mumu.nemux-global") == "Nemux Global")
        #expect(Leftover.displayName("com.tw93.MoleApp") == "MoleApp")
        #expect(Leftover.displayName("com.FluidApp.app") == "FluidApp App")
        #expect(Leftover.displayName("net.imput.helium") == "Helium")
    }

    @Test func protectedPaths() {
        let item = "/Users/me/Library/Caches/com.foo.Bar"
        #expect(LeftoverScanner.isProtected(item, by: [item]))
        #expect(LeftoverScanner.isProtected(item, by: ["/Users/me/Library/Caches"]))
        #expect(LeftoverScanner.isProtected(item, by: ["/Users/*/Library/Caches/com.foo*"]))
        #expect(LeftoverScanner.isProtected(item, by: [item + "/keep.db"]))
        #expect(LeftoverScanner.isProtected(item, by: ["/Users/*/Library/Caches/com.foo.Bar/*"]))
        #expect(!LeftoverScanner.isProtected(item, by: ["/Users/me/Library/Caches/com.other"]))
        #expect(!LeftoverScanner.isProtected(item, by: ["/Users/me/Library/Logs"]))
        // `*` crosses folders, as in Mole.
        #expect(LeftoverScanner.isProtected(item, by: ["/Users/me/*/com.foo.Bar"]))
    }

    @Test func protectedFileDeepInside() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-\(UUID().uuidString)")
        let item = root.appendingPathComponent("Caches/com.foo.Bar")
        try FileManager.default.createDirectory(at: item.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: item.appendingPathComponent("a/b/keep.db").path, contents: Data())
        #expect(LeftoverScanner.isProtected(item.path, by: [root.path + "/*/keep.db"]))
        #expect(!LeftoverScanner.isProtected(item.path, by: [root.path + "/*/other.db"]))
    }

    @Test func moleProtectsItsSensitiveBundles() throws {
        let kept = try #require(LeftoverScanner.protectedByMole(["com.authy.authy", "com.yubico.yubioath", "org.cups.PrintingPrefs", "com.tw93.MoleApp"]))
        #expect(kept == ["com.authy.authy", "com.yubico.yubioath", "org.cups.PrintingPrefs"])
    }

    @Test func staleness() {
        #expect(ResultCache.isStale(nil))
        #expect(!ResultCache.isStale(Date()))
        #expect(ResultCache.isStale(Date().addingTimeInterval(-ResultCache.staleAfter - 1)))
    }

    @Test func removedAppsDiff() {
        let trash = "/Users/me/.Trash"
        let seen = ["/Applications/A.app": "com.a", "/Applications/B.app": "com.b", "/Applications/C.app": "com.c",
                    "/Applications/NoID.app": "", trash + "/Old.app": "com.old"]
        // A went to the Trash, B was renamed, C is still there, NoID has no bundle id, Old left the Trash.
        let now = [trash + "/A.app": "com.a", "/Applications/B 2.app": "com.b", "/Applications/C.app": "com.c"]
        #expect(LeftoverStore.removedApps(seen: seen, now: now) == ["com.a": "/Applications/A.app"])
        #expect(LeftoverStore.removedApps(seen: seen, now: seen).isEmpty)
    }

    @Test func runProgress() {
        // A slim run as the sheet sees it: menu rows, the confirm list, the prompt, then the work.
        let slim = ["○ Steam                4.9MB", "Apps to slim:", "◎ Google Chrome , 576.3MB", "◎ Zoom, 120MB",
                    "Originals move to the Trash. App updates bring the Intel code back.",
                    "➤ Slim 2 apps, 696.3MB  Enter confirm, ESC cancel:",
                    "✓ [1/2] Google Chrome , 576.3MB", "◎ [2/2] Zoom, could not move the original to Trash"]
        let p = RunProgress.parse(lines: slim, live: "⠙ [2/2] Slimming Zoom...")
        #expect(p.steps.map(\.kind) == [.done, .note])
        #expect(p.steps[0].name == "Google Chrome" && p.steps[0].bytes == 576_300_000 && p.steps[0].section == nil)
        #expect(p.now == "Slimming Zoom" && p.position?.at == 2 && p.position?.of == 2)
        #expect(p.freed == 576_300_000)
        #expect(p.planned.map(\.name) == ["Google Chrome", "Zoom"] && p.planned[1].bytes == 120_000_000)
        let done = RunProgress.parse(lines: slim + ["Slimmed 1 app, freed 580MB: Google Chrome"], live: "")
        #expect(done.freed == 580_000_000 && done.now == nil)

        // A size in a name or a warning: the summary is anchored, sized warnings after work stay warnings.
        let odd = RunProgress.parse(lines: ["✓ [1/2] Tool, 1GB", "◎ [2/2] Tool 2GB, still running",
                                            "Slimmed 1 app, freed 1GB: Tool", "Freed 2TB", "✓ Huge, 99999999999TB"], live: "")
        #expect(odd.steps.map(\.kind) == [.done, .note, .done] && odd.freed == 1_000_000_000)
        #expect(odd.position?.at == 2 && odd.positionDone)
        // Uninstall lists files with ✓ before it asks; declining leaves nothing done.
        let declined = RunProgress.parse(lines: ["✓ ~/Library/Caches/com.app", "➤ Remove 1 app, 2MB  Enter confirm, ESC cancel:"], live: "")
        #expect(declined.steps.isEmpty)

        let clean = RunProgress.parse(lines: ["➤ Notification Center", "✓ Chrome, freed 5MB", "➤ User essentials", "✓ User app cache · 12 items, 1.20GB", "✓ Trash · emptied",
                                              "Tracked cleanup: 1.5GB"], live: "")
        #expect(clean.steps.map(\.section) == ["Notification Center", "User essentials", "User essentials"])
        #expect(clean.steps[1].detail == "12 items, 1.20GB" && clean.steps[2].bytes == nil)
        #expect(clean.freed == 1_500_000_000)
    }

    @Test func uninstallProgress() {
        // Recorded from mo uninstall: the match list, the files for the confirmation, then the run.
        let listed = ["◎ Matched 2 app(s):", "1. LinearMouse  --  |  Last: 1m ago", "2. Qalta  74.8MB  |  Last: 2d ago",
                      "Files to be removed:", "◎ LinearMouse , 15.8MB", "✓ /Applications/LinearMouse.app , 15.8MB",
                      "◎ System: /Library/LaunchDaemons/com.lujjjh.plist", "◎ Qalta , 74.8MB", "✓ /Applications/Qalta.app , 74.8MB",
                      "Personal data kept:", "⊙ ~/Library/Containers/com.qalta", "D choose personal data"]
        let asking = RunProgress.parse(lines: listed, live: "➤ Remove 2 apps, 90.5MB  Enter confirm, ESC cancel: ")
        #expect(asking.steps.isEmpty && !asking.dryRun)
        #expect(asking.planned.map(\.name) == ["LinearMouse", "Qalta"] && asking.planned[0].bytes == 15_800_000)
        #expect(asking.planned[1].detail == "Last used 2d ago")
        #expect(asking.review.map(\.name) == ["LinearMouse.app", "com.lujjjh.plist", "Qalta.app"])
        #expect(asking.review[1].section == "LinearMouse" && asking.review[1].detail == "System · /Library/LaunchDaemons")

        let confirmed = listed + ["➤ Remove 2 apps, 90.5MB  Enter confirm, ESC cancel:", "✓ [1/2] LinearMouse"]
        let running = RunProgress.parse(lines: confirmed, live: "⠼ [2/2] Removing Qalta (74.8MB)...")
        #expect(running.review.isEmpty && running.steps.map(\.name) == ["LinearMouse"])
        #expect(running.now == "Removing Qalta" && running.position?.at == 2)

        // One app prints no "✓ [1/1]"; the closing line names it.
        let single = RunProgress.parse(lines: ["◎ Matched 1 app(s):", "1. CounterFlame  2.66GB  |  Last: 2d ago",
                                               "➤ Remove 1 app, 2.66GB  Enter confirm, ESC cancel:",
                                               "Uninstall complete", "Removed 1 app, freed 2.66GB: CounterFlame"], live: "")
        #expect(single.steps.map(\.name) == ["CounterFlame"] && single.freed == 2_660_000_000)

        // Optimize's diagnosis comes before any section; a size in it is not a list of work.
        let optimize = RunProgress.parse(lines: ["◎ Memory pressure: swap 15.21GB of 16.11GB used (94%), 36% free",
                                                 "➤ Network Cache Refresh", "✓ DNS cache refreshed"], live: "")
        #expect(optimize.planned.isEmpty && optimize.steps.map(\.kind) == [.note, .done])

        #expect(QuickReply.title(for: "➤ Remove 2 apps, 90.5MB  Enter confirm, ESC cancel: ") == "Remove 2 apps, 90.5MB?")
        #expect(QuickReply.options(for: "➤ Remove 2 apps, 90.5MB  Enter confirm, ESC cancel: ").map(\.label) == ["Remove", "Cancel"])
        #expect(QuickReply.title(for: "⊙ Detach now? Enter confirm / Space cancel: ") == "Detach now?")
        #expect(QuickReply.title(for: "Proceed? [y/N]: ") == "Proceed?")
        #expect(QuickReply.title(for: "Password:") == "Password:")

        let preview = RunProgress.parse(lines: ["→ DRY RUN MODE, No app files or settings will be modified"] + listed
                                        + ["➤ Remove 2 apps, 90.5MB  Enter confirm, ESC cancel:", "Would remove 2 apps, would free 90.5MB: LinearMouse, Qalta"], live: "")
        #expect(preview.dryRun && preview.review.count == 3 && preview.freed == 90_500_000)
    }

    @Test func purgeKeepsResultsWhenSomeFoldersCouldNotBeChecked() {
        // Mole exits 1 here, after a whole summary; the warnings come on stderr, after stdout.
        let out = """
            → [DRY RUN] ~/PROJECTS/app/node_modules, 1.20GB
            → [DRY RUN] ~/PROJECTS/site/dist, 3.5MB
            ======================================================================
            Dry run incomplete - no changes made
            Would free approximately: 1.20GB | Items: 2 | Free: 81.00GB
            ======================================================================

            ◎ Could not inspect ~/PROJECTS/a/dist; kept
            ◎ Could not inspect ~/PROJECTS/b/dist; kept
            ◎ Could not inspect ~/PROJECTS/c/dist; kept
            ◎ Could not inspect ~/PROJECTS/d/dist; kept
            """
        let r = PurgeReport.parse(out)
        #expect(r.complete && r.artifacts.count == 2)
        #expect(r.uninspected == ["~/PROJECTS/a/dist", "~/PROJECTS/b/dist", "~/PROJECTS/c/dist", "~/PROJECTS/d/dist"])
        #expect(r.notes.last?.hasSuffix("~/PROJECTS/c/dist and 1 more") == true)
        // Cut off before the summary: not a whole result.
        #expect(!PurgeReport.parse("→ [DRY RUN] ~/PROJECTS/app/node_modules, 1.20GB").complete)
    }
}
