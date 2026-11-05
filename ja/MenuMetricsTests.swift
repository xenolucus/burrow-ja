import Foundation
import Testing
@testable import Burrow

struct MenuMetricsTests {
    private func status(_ json: String) throws -> SystemStatus {
        try JSONDecoder().decode(SystemStatus.self, from: Data(json.utf8))
    }

    @Test func formatsColumns() throws {
        let s = try status(#"""
        {"cpu":{"usage":18.4},"memory":{"used":1,"total":2,"used_percent":61.6},
         "disks":[{"mount":"/","used":500000000000,"total":1000000000000}],
         "network":[{"name":"en0","rx_rate_mbs":1.26,"tx_rate_mbs":0.1},{"name":"en1","rx_rate_mbs":1,"tx_rate_mbs":0}]}
        """#)
        #expect(MenuMetric.cpu.lines(s)?.bottom == "18%")
        #expect(MenuMetric.memory.lines(s)?.bottom == "62%")
        #expect(MenuMetric.disk.lines(s)?.bottom == "500G")
        #expect(MenuMetric.network.lines(s)?.top == "↑0.1" && MenuMetric.network.lines(s)?.bottom == "↓2.3")
        #expect(MenuMetric.battery.lines(s) == nil)
    }

    @Test func keepsOnlyKnownMetrics() {
        #expect(MenuMetric.selected("network,nope,cpu") == [.cpu, .network])
        #expect(MenuMetric.selected("").isEmpty)
    }
}
