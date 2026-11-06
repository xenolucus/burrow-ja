import Foundation
import Testing
@testable import Burrow

private extension String {
    var lastPathComponentName: String { (self as NSString).lastPathComponent }
}

struct MenuMetricsTests {
    private func status(_ json: String) throws -> SystemStatus {
        try JSONDecoder().decode(SystemStatus.self, from: Data(json.utf8))
    }

    @Test func formatsCells() throws {
        let s = try status(#"""
        {"cpu":{"usage":18.4},"memory":{"used":1,"total":2,"used_percent":61.6},
         "thermal":{"cpu_temp":0,"battery_temp":34.5},
         "disks":[{"mount":"/","used":500000000000,"total":1000000000000}],
         "network":[{"name":"en0","rx_rate_mbs":1.26,"tx_rate_mbs":0.1},{"name":"en1","rx_rate_mbs":1,"tx_rate_mbs":0}]}
        """#)
        let power = PowerMeter.Reading(inputWatts: 16.3, loadWatts: 11.1, hoursLeft: 6.32)
        #expect(MenuMetric.cpu.cell(s, power: nil)?.bottom == "18%")
        #expect(MenuMetric.memory.cell(s, power: nil)?.bottom == "62%")
        #expect(MenuMetric.disk.cell(s, power: nil)?.bottom == "500G")
        #expect(MenuMetric.temperature.cell(s, power: nil)?.bottom == "34℃" || MenuMetric.temperature.cell(s, power: nil)?.bottom == "35℃")
        #expect(MenuMetric.network.cell(s, power: nil)?.top == "↑100K")
        #expect(MenuMetric.network.cell(s, power: nil)?.bottom == "↓2.3M")
        #expect(MenuMetric.power.cell(s, power: power)?.top == "入 16W")
        #expect(MenuMetric.power.cell(s, power: power)?.bottom == "使 11W")
        #expect(MenuMetric.runtime.cell(s, power: power)?.bottom == "6.3h")
        #expect(MenuMetric.battery.cell(s, power: nil) == nil)
        #expect(MenuMetric.power.cell(s, power: nil) == nil)
    }

    @Test func labelsCanBeHidden() {
        let cell = MenuMetric.Cell(top: "入 16W", bottom: "使 11W", widest: "使 188W", pair: true).withoutLabels()
        #expect(cell.top == "16W" && cell.bottom == "11W" && cell.widest == "188W")
        let network = MenuMetric.Cell(top: "↑1K", bottom: "↓2K", widest: "↓888K", pair: true).withoutLabels()
        #expect(network.top == "↑1K" && network.bottom == "↓2K")
    }

    @Test func speedStaysShort() {
        #expect(MenuMetric.speed(0) == "0K")
        #expect(MenuMetric.speed(0.999) == "1.0M")
        #expect(MenuMetric.speed(12.4) == "12M")
    }

    @Test func estimatesHoursFromRemainingEnergy() throws {
        let hours = try #require(PowerMeter.hours(milliampHours: 5362, millivolts: 13047, watts: 11))
        #expect(abs(hours - 6.36) < 0.01)
        #expect(PowerMeter.hours(milliampHours: 5362, millivolts: 13047, watts: 0) == nil)
        #expect(PowerMeter.hours(milliampHours: 0, millivolts: 13047, watts: 11) == nil)
    }

    @Test func onlyExternalVolumesAreOffered() {
        #expect(ExternalDrives.isCandidate(path: "/Volumes/Backup", isInternal: false))
        #expect(!ExternalDrives.isCandidate(path: "/Volumes/Macintosh HD", isInternal: true))
        #expect(!ExternalDrives.isCandidate(path: "/Volumes/Unknown", isInternal: nil))
        #expect(!ExternalDrives.isCandidate(path: "/", isInternal: false))
        #expect(!ExternalDrives.isCandidate(path: "/Volumes/Backup/Sub", isInternal: false))
    }

    @Test func cachesAreMatchedNarrowly() {
        #expect(ExternalCacheScanner.kind(name: "Media Cache Files", parent: "Adobe", siblings: []) != nil)
        #expect(ExternalCacheScanner.kind(name: "shadercache", parent: "steamapps", siblings: []) != nil)
        #expect(ExternalCacheScanner.kind(name: "shadercache", parent: "Work", siblings: []) == nil)
        #expect(ExternalCacheScanner.kind(name: "Library", parent: "Game", siblings: ["Assets", "ProjectSettings"]) != nil)
        #expect(ExternalCacheScanner.kind(name: "Library", parent: "Photos", siblings: ["Assets"]) == nil)
        #expect(ExternalCacheScanner.kind(name: "Documents", parent: "Work", siblings: []) == nil)
        #expect(ExternalCacheScanner.kind(name: "Disk Cache - MacBook Pro", parent: "25.5", siblings: []) != nil)
        #expect(ExternalCacheScanner.kind(name: "Adobe After Effects Disk Cache - Mac", parent: "Cache", siblings: []) != nil)
        #expect(ExternalCacheScanner.kind(name: "Adobe Premiere Pro Video Previews", parent: "Project", siblings: []) != nil)
        #expect(ExternalCacheScanner.kind(name: "Adobe Premiere Pro Audio Previews", parent: "Project", siblings: []) != nil)
        #expect(ExternalCacheScanner.kind(name: "Adobe Premiere Pro Auto-Save", parent: "Project", siblings: []) == nil)
        #expect(ExternalCacheScanner.kind(name: "Disk Cache", parent: "Work", siblings: []) == nil)
    }

    @Test func scanFindsOnlyKnownFoldersAndSkipsLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let cache = root.appendingPathComponent("Adobe/Media Cache Files")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: cache.appendingPathComponent("a.bin"))
        try fm.createDirectory(at: root.appendingPathComponent("Movies/Project"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Peak Files"), withDestinationURL: cache)
        let found = ExternalCacheScanner.scan(root, minBytes: 1)
        #expect(found.map(\.path.lastPathComponentName) == ["Media Cache Files"])
    }

    @Test func adobeTempCountsOnlyAtTheVolumeTop() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        for folder in [".adobeTemp", "Work/.adobeTemp", "Project/Adobe Premiere Pro Audio Previews"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data(count: 4096).write(to: root.appendingPathComponent(".adobeTemp/a.tmp"))
        try Data(count: 4096).write(to: root.appendingPathComponent("Work/.adobeTemp/a.tmp"))
        let found = ExternalCacheScanner.scan(root, minBytes: 1)
        #expect(found.map(\.path.lastPathComponentName) == [".adobeTemp"])
        #expect(ExternalCacheScanner.scan(root, minBytes: 1_000_000).isEmpty)
    }

    @Test func cleaningGoesToTheRightPlace() {
        let plan = ExternalCache.split([
            .init(path: "/Volumes/SSD/Media Cache", kind: "", bytes: 1),
            .init(path: "/Volumes/SSD", kind: "", bytes: 1, byMole: true),
        ])
        #expect(plan.trash == ["/Volumes/SSD/Media Cache"])
        #expect(plan.mole == ["/Volumes/SSD"])
    }

    @Test func totalsCountRealRunsOnce() throws {
        let json = #"""
        [{"command":"clean","started_at":"2026-11-05 13:10:00","size":"13.52GB","items":754},
         {"command":"clean-dry-run","started_at":"2026-11-05 13:11:00","size":"5GB","items":9},
         {"command":"uninstall","started_at":"2026-11-05 13:12:00","size":"0B","items":0}]
        """#
        let sessions = try JSONDecoder().decode([HistoryResult.Session].self, from: Data(json.utf8))
        let first = TotalsStore.merged([], with: sessions)
        #expect(first.map(\.kind) == ["clean"])
        #expect(TotalsStore.merged(first, with: sessions).count == 1)
        let rows = TotalsStore.breakdown(first + [.init(id: "x", kind: "clean", bytes: 1, date: Date())])
        #expect(rows.count == 1 && rows[0].runs == 2)
    }

    @Test func safeCachesStartSelected() {
        let found: [ExternalCache] = [
            .init(path: "/Volumes/SSD/Adobe/Media Cache", kind: "", bytes: 1),
            .init(path: "/Volumes/SSD/.adobeTemp", kind: "", bytes: 1),
            .init(path: "/Volumes/SSD/Game/Library", kind: "", bytes: 1),
            .init(path: "/Volumes/SSD", kind: "", bytes: 1, byMole: true),
        ]
        #expect(ExternalCache.preselected(found, adobeRunning: false)
                == ["/Volumes/SSD/Adobe/Media Cache", "/Volumes/SSD/.adobeTemp", "/Volumes/SSD"])
        #expect(!ExternalCache.preselected(found, adobeRunning: true).contains("/Volumes/SSD/.adobeTemp"))
    }

    @Test func removalStaysInsideTheDrive() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let drive = root.appendingPathComponent("Drive"), outside = root.appendingPathComponent("Other")
        let cache = drive.appendingPathComponent("Media Cache"), link = drive.appendingPathComponent("Peak Files")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let base = drive.standardizedFileURL.path
        let left = ExternalCache.remove([cache.path, link.path, outside.path], under: base)
        #expect(!fm.fileExists(atPath: cache.path))
        #expect(left == [link.path, outside.path])
        #expect(fm.fileExists(atPath: outside.path) && (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test func parsesDriveInfo() throws {
        let plist: [String: Any] = ["MediaName": "SSD", "BusProtocol": "USB", "FilesystemUserVisibleName": "APFS",
                                    "SMARTStatus": "Not Supported", "TotalSize": 1000, "APFSContainerFree": 400]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let info = try #require(DriveInfo.parse(data))
        #expect(info.model == "SSD" && info.free == 400 && info.total == 1000)
        #expect(info.health == "このドライブでは取得できません")
        #expect(DriveInfo.parse(Data("x".utf8)) == nil)
    }

    @Test func oldVideoRule() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-OldVideoScanner.idle - 1)
        #expect(OldVideoScanner.isOld(path: "/V/a.MOV", bytes: OldVideoScanner.minBytes, lastUsed: old, now: now))
        #expect(!OldVideoScanner.isOld(path: "/V/a.mov", bytes: OldVideoScanner.minBytes - 1, lastUsed: old, now: now))
        #expect(!OldVideoScanner.isOld(path: "/V/a.mov", bytes: OldVideoScanner.minBytes, lastUsed: now, now: now))
        #expect(!OldVideoScanner.isOld(path: "/V/a.psd", bytes: OldVideoScanner.minBytes, lastUsed: old, now: now))
    }

    @Test func spacingLabel() {
        #expect(MenuSpacing.label(nil) == "標準")
        #expect(MenuSpacing.label(7) == "7 pt")
    }

    @Test func metricsMoveWithinTheirOrder() {
        #expect(MenuMetric.moved(.cpu, by: 1, in: [.cpu, .memory]) == [.memory, .cpu])
        #expect(MenuMetric.moved(.cpu, by: -1, in: [.cpu, .memory]) == nil)
        #expect(MenuMetric.moved(.memory, by: 1, in: [.cpu, .memory]) == nil)
    }

    @Test func everyStyleDrawsInTheMenuBarHeight() throws {
        let s = try status(#"{"cpu":{"usage":18.4},"memory":{"used":1,"total":2,"used_percent":61.6},"network":[{"name":"en0","rx_rate_mbs":1,"tx_rate_mbs":0}]}"#)
        for style in MenuStyle.allCases {
            for labels in [true, false] {
                let image = MenuMetric.image([.cpu, .memory, .network], look: MenuLook(style: style, labels: labels), status: s, power: nil)
                #expect(image.size.height == 22 && image.size.width > 40)
            }
        }
    }

    @Test func hideListAllowsEverythingElse() {
        let list = HideList.make(running: ["a", "b"], hidden: ["b", "quit"], own: "self")
        #expect(list.allowed == ["a", "self"])
        #expect(list == HideList.make(running: ["self", "b", "a"], hidden: ["quit", "b"], own: "self"))
        #expect(list != HideList.make(running: ["a", "b", "c"], hidden: ["b", "quit"], own: "self"))
    }

    @Test func labelsKeepTheirPlaceForEverydayValues() {
        let small = MenuMetric.Cell(top: "残り", bottom: "4.1h", widest: "88.8h", usual: "8.8h").fitted()
        let large = MenuMetric.Cell(top: "残り", bottom: "9.9h", widest: "88.8h", usual: "8.8h").fitted()
        #expect(small.widest == large.widest)
        let long = MenuMetric.Cell(top: "残り", bottom: "12.5h", widest: "88.8h", usual: "8.8h").fitted()
        #expect(long.widest == "12.5h")
        let power = MenuMetric.Cell(top: "入 0W", bottom: "使 1W", widest: "使 188W", usual: "使 88W", pair: true)
        #expect(power.withoutLabels().usual == "88W")
    }

    @Test func insetsWidenTheImage() throws {
        let s = try status(#"{"cpu":{"usage":18.4}}"#)
        let plain = MenuMetric.image([.cpu], look: MenuLook(), status: s, power: nil).size.width
        let padded = MenuMetric.image([.cpu], look: MenuLook(leading: 3, trailing: 5), status: s, power: nil).size.width
        #expect(padded == plain + 8)
    }

    @Test func onlyThirdPartyAppsCanBeHidden() {
        #expect(MenuHider.listable("com.tinyspeck.slackmacgap", own: "me"))
        #expect(!MenuHider.listable("com.apple.controlcenter", own: "me"))
        #expect(!MenuHider.listable("me", own: "me"))
    }

    @Test func makingRoomKeepsOnlyTheOpenedApps() {
        let list = MenuHider.withRoom(["hidden"], running: ["a", "open", "me", "com.apple.x"], keep: ["open"], own: "me")
        #expect(list == ["hidden", "a"])
    }

    @Test func alertsRepeatOnlyAfterTheirInterval() {
        let now = Date()
        #expect(DiskAlert.isDue(last: nil, every: 60, now: now))
        #expect(!DiskAlert.isDue(last: now.addingTimeInterval(-59), every: 60, now: now))
        #expect(DiskAlert.isDue(last: now.addingTimeInterval(-60), every: 60, now: now))
    }

    @Test func heavyAppsAddUpHelpersAndSkipSystemAndSelf() {
        let text = """
         40.0 /Applications/Discord.app/Contents/MacOS/Discord
         20.5 /Applications/Discord.app/Contents/Frameworks/Discord Helper.app/Contents/MacOS/Discord Helper
         90.0 /System/Applications/Mail.app/Contents/MacOS/Mail
         50.0 /usr/libexec/rtcreportingd
         70.0 /Applications/Burrow JA.app/Contents/MacOS/Burrow
          1.0 /Applications/Quiet.app/Contents/MacOS/Quiet
        """
        let apps = HeavyApps.parse(text, own: "/Applications/Burrow JA.app")
        #expect(apps == [HeavyApp(path: "/Applications/Discord.app", cpu: 60.5)])
        #expect(apps[0].name == "Discord")
    }

    @Test func manualGuideCoversDockerWithoutRunningAnything() {
        #expect(ManualGuide.all["Docker Desktop data"]?.command == "docker system prune -a")
    }

    @Test func duplicatesCompareContentAndAlwaysKeepOneCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = Data(repeating: 1, count: 2_000_000), other = Data(repeating: 2, count: 2_000_000)
        try one.write(to: root.appendingPathComponent("a.bin"))
        try one.write(to: root.appendingPathComponent("b.bin"))
        try other.write(to: root.appendingPathComponent("sameSizeOnly.bin"))
        try Data(repeating: 1, count: 10).write(to: root.appendingPathComponent("tiny1"))
        try Data(repeating: 1, count: 10).write(to: root.appendingPathComponent("tiny2"))
        try FileManager.default.linkItem(at: root.appendingPathComponent("a.bin"), to: root.appendingPathComponent("hardlink.bin"))
        let groups = DuplicateFinder.scan([root])
        #expect(groups.count == 1)
        #expect(groups[0].files.count == 2)
        #expect(groups[0].extra == 2_000_000)
        let kept = groups[0].files[0].path
        let removed = DuplicateFinder.allButNewest(groups)
        #expect(!removed.contains(kept) && removed.count == 1)
        #expect(!DuplicateFinder.canSelect(kept, in: groups[0], selected: removed))
    }

    @Test func remainingReadsTheNewestRunOfEachKind() {
        let log = """
        [2026-11-06 09:00:00] [clean run=old] SKIPPED /h/Library/Caches/gone (protected)
        [2026-11-06 10:00:00] [clean run=new] FAILED /h/.npm/_cacache/index-v5 (permission denied)
        [2026-11-06 10:00:01] [clean run=new] REMOVED /h/Library/Caches/x
        [2026-11-06 12:00:00] [clean-dry-run run=dry] SKIPPED /h/Library/Caches/a b (c) (protected)
        """
        let found = Remaining.parse(log)
        #expect(Set(found.map(\.path)) == ["/h/.npm/_cacache/index-v5", "/h/Library/Caches/a b (c)"])
    }

    @Test func remainingOffersOnlyThirdPartyCaches() {
        let home = "/h"
        func top(_ path: String, _ reason: String = "protected") -> String? { Remaining.candidate(path, reason: reason, home: home)?.path }
        #expect(top("/h/Library/Caches/com.spotify.client") == "/h/Library/Caches/com.spotify.client")
        #expect(top("/h/Library/Logs/OneDrive") == "/h/Library/Logs/OneDrive")
        #expect(top("/h/Library/Caches/notion.id/Cache.db", "live user cache") == "/h/Library/Caches/notion.id")
        #expect(top("/h/Library/Containers/jp.naver.line.mac/Data/Library/Caches/WebKit", "live user cache")
            == "/h/Library/Containers/jp.naver.line.mac/Data/Library/Caches")
        #expect(top("/h/.npm/_cacache/content-v2", "permission denied") == "/h/.npm/_cacache/content-v2")
        #expect(top("/h/Library/Caches/com.apple.akd") == nil)
        #expect(top("/h/Library/Containers/com.apple.x/Data/Library/Caches/y", "live user cache") == nil)
        #expect(top("/h/Library/Caches/CloudKit") == nil)
        #expect(top("/h/Library/Logs/mole") == nil)
        #expect(top("/h/Library/Caches/GeoServices/networkDefaults.plist") == nil)
        #expect(top("/h/Library/Caches/foo", "whitelist") == nil)
        #expect(top("/h/Library/Caches/foo", "active or unknown SQLite database") == nil)
        #expect(top("/h/Library/Caches/foo/../../Mail") == nil)
        #expect(top("/h/.npm/_cacache/content-v2") == nil)
    }

    @Test func remainingQuotesPathsForTheShell() {
        #expect(Remaining.shellQuoted(["/h/a b", "/h/it's"]) == "'/h/a b' '/h/it'\\''s'")
    }

    @Test func maxCleanLiftsOnlyReplaceableCachesAndRestoresThem() {
        let home = NSHomeDirectory()
        let saved = ["\(home)/Library/Caches/JetBrains*", "~/.gradle/caches/*", "~/Library/Mobile Documents*", "~/mine"]
        let on = MaxClean.entries(saved, on: true)
        #expect(on == ["~/Library/Mobile Documents*", "~/mine"])
        #expect(MaxClean.isOn(on))
        #expect(!MaxClean.isOn(saved))
        let off = MaxClean.entries(on, on: false)
        #expect(!MaxClean.isOn(off))
        #expect(Set(off).isSuperset(of: MaxClean.replaceable + ["~/mine"]))
        #expect(!MaxClean.isOn([]))
        #expect(MaxClean.entries([], on: true).contains("~/Library/Mobile Documents*"))
    }

    @Test func pagesCycleThroughEveryGroupAndAll() {
        let groups = [MenuGroup(id: "1"), MenuGroup(id: "2")]
        #expect(MenuHider.nextPage(after: nil, groups: groups) == "1")
        #expect(MenuHider.nextPage(after: "1", groups: groups) == "2")
        #expect(MenuHider.nextPage(after: "2", groups: groups) == MenuHider.allPage)
        #expect(MenuHider.nextPage(after: MenuHider.allPage, groups: groups) == "1")
        #expect(MenuHider.stillHidden([MenuGroup(id: "1", apps: ["a"])], expanded: [MenuHider.allPage], passing: nil).isEmpty)
    }

    @Test func openingAGroupShowsOnlyItsApps() {
        let one = MenuGroup(id: "1", apps: ["a", "b"]), two = MenuGroup(id: "2", apps: ["c"])
        #expect(MenuHider.stillHidden([one, two], expanded: [], passing: nil) == ["a", "b", "c"])
        #expect(MenuHider.stillHidden([one, two], expanded: ["1"], passing: nil) == ["c"])
        #expect(MenuHider.stillHidden([one, two], expanded: [], passing: "c") == ["a", "b"])
    }

    @Test func groupsKeepOlderHiddenApps() throws {
        let moved = MenuGroup.load(saved: nil, legacy: ["a"])
        #expect(moved.count == 1 && moved[0].apps == ["a"])
        let saved = [MenuGroup(name: "x", symbol: "star", apps: ["b"]), MenuGroup(name: "y")]
        let data = try JSONEncoder().encode(saved)
        #expect(MenuGroup.load(saved: data, legacy: ["a"]) == saved)
        #expect(MenuGroup.load(saved: Data("bad".utf8), legacy: []).count == 1)
    }

    @Test func iconCleanerRemovesTheBackground() {
        // A 3 × 1 picture: light glyph on a mid-grey bar.
        var light: [UInt8] = [120, 120, 120, 255, 250, 250, 250, 255, 120, 120, 120, 255]
        MenuIconCleaner.clean(&light, width: 3, height: 1)
        #expect(light[3] == 0 && light[11] == 0)
        #expect(light[7] == 255 && light[4] > 200)
        // A dark glyph turns light, because the panel is dark.
        var dark: [UInt8] = [220, 220, 220, 255, 10, 10, 10, 255, 220, 220, 220, 255]
        MenuIconCleaner.clean(&dark, width: 3, height: 1)
        #expect(dark[7] == 255 && dark[4] > 200)
        // A coloured badge keeps its colour.
        var badge: [UInt8] = [220, 220, 220, 255, 10, 10, 10, 255, 220, 40, 40, 255, 220, 220, 220, 255]
        MenuIconCleaner.clean(&badge, width: 4, height: 1)
        #expect(badge[8] > badge[9])
    }

    @Test func sidebarOrderAndExtras() {
        let standard: [Page] = [.overview, .clean, .uninstall, .optimize, .analyze, .projects, .installers, .drives, .slim, .menubar]
        #expect(Page.main(order: "", hidden: "") == standard)
        #expect(Page.sidebar(order: "", hidden: "").suffix(3) == [.history, .totals, .settings])
        let reordered = Page.main(order: "clean,overview", hidden: "drives,menubar")
        #expect(reordered.prefix(2) == [.clean, .overview] && !reordered.contains(.drives) && !reordered.contains(.menubar))
        #expect(reordered.contains(.slim))
        #expect(!Page.sidebar(order: "", hidden: "totals").contains(.totals))
        #expect(Page.moved(.overview, by: -1, in: standard) == nil)
        #expect(Page.moved(.clean, by: -1, in: standard)?.first == .clean)
    }

    @Test func keepsOnlyKnownMetrics() {
        #expect(MenuMetric.selected("network,nope,cpu") == [.network, .cpu])
        #expect(MenuMetric.selected("").isEmpty)
    }
}
