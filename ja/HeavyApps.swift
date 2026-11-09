import AppKit
import SwiftUI

struct HeavyApp: Identifiable, Equatable {
    let path: String
    let cpu: Double
    var id: String { path }
    var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
}

enum HeavyApps {
    /// `ps -Ao pcpu=,comm=` lines, with helper processes counted towards their app. System apps are left out.
    static func parse(_ text: String, own: String) -> [HeavyApp] {
        var totals: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let cpu = Double(parts[0]), let end = parts[1].range(of: ".app/") else { continue }
            let app = String(parts[1][..<end.lowerBound]) + ".app"
            guard app.contains("/Applications/"), !app.hasPrefix("/System/"), app != own else { continue }
            totals[app, default: 0] += cpu
        }
        return totals.filter { $0.value >= 5 }.map { HeavyApp(path: $0.key, cpu: $0.value) }
            .sorted { $0.cpu > $1.cpu }.prefix(5).map { $0 }
    }

    static func load() -> [HeavyApp] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pcpu=,comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self), own: Bundle.main.bundlePath)
    }
}

/// Which apps are behind a busy diagnosis, and a way to close them.
struct HeavyAppsCard: View {
    @ViewState private var apps: [HeavyApp] = []

    var body: some View {
        Group {
            if !apps.isEmpty {
                GlowCard(glow: .ember, style: .rim, padding: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("負荷の高いアプリ").cardTitle()
                            Spacer()
                            Button("更新") { Task { await reload() } }.buttonStyle(.link).font(.system(size: 12))
                        }
                        Text("補助プロセスもアプリごとに合計した今の CPU 使用率です。100% でコア1つ分です。").caption()
                        ForEach(apps) { row($0) }
                    }
                }
            }
        }
        .task { await reload() }
    }

    private func row(_ app: HeavyApp) -> some View {
        HStack {
            Text(verbatim: app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer()
            Text("\(Int(app.cpu))%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            Button("終了") { quit(app) }.buttonStyle(.pillSecondary)
        }
    }

    private func reload() async {
        apps = await Task.detached(priority: .utility) { HeavyApps.load() }.value
    }

    /// Asks politely, so an app with unsaved work can still say no.
    private func quit(_ app: HeavyApp) {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == app.path }?.terminate()
        Task {
            try? await Task.sleep(for: .seconds(2))
            await reload()
        }
    }
}
