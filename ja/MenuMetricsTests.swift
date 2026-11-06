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

    @Test func keepsOnlyKnownMetrics() {
        #expect(MenuMetric.selected("network,nope,cpu") == [.cpu, .network])
        #expect(MenuMetric.selected("").isEmpty)
    }
}
