import Foundation
import Testing
@testable import Burrow

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

    @Test func keepsOnlyKnownMetrics() {
        #expect(MenuMetric.selected("network,nope,cpu") == [.cpu, .network])
        #expect(MenuMetric.selected("").isEmpty)
    }
}
