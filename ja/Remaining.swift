import AppKit
import SwiftUI

/// Something Mole left behind on its last clean or preview, offered for the user to remove by hand.
struct RemainingItem: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let owner: String
    let bytes: Int64
    let needsAdmin: Bool
    var id: String { path }
}

enum Remaining {
    private static let reasons: Set<String> = ["protected", "live user cache", "permission denied"]
    /// Apple's own, or Mole's and this app's records. Never offered.
    private static let keptOwners: Set<String> = ["CloudKit", "FamilyCircle", "GeoServices", "mole", "Mole", "io.github.xenolucus.burrow-ja"]
    private static let keptPrefixes = ["com.apple.", "group.com.apple.", "developer.apple."]

    /// (path, reason) from the newest clean and the newest preview: previews never report busy or denied items.
    static func parse(_ log: String) -> [(path: String, reason: String)] {
        let line = #/\[clean(-dry-run)? run=([^\]]+)\] (?:SKIPPED|FAILED) (.+) \(([^()]+)\)$/#
        var runs: [Bool: (id: Substring, items: [(path: String, reason: String)])] = [:]
        for text in log.split(whereSeparator: \.isNewline) {
            guard let match = text.firstMatch(of: line) else { continue }
            let preview = match.1 != nil
            if runs[preview]?.id != match.2 { runs[preview] = (match.2, []) }
            runs[preview]?.items.append((String(match.3), String(match.4)))
        }
        return runs.values.flatMap(\.items)
    }

    /// The folder to offer for a logged path and who owns it, or nil when it must stay.
    static func candidate(_ path: String, reason: String, home: String) -> (path: String, owner: String)? {
        guard reasons.contains(reason), path.hasPrefix(home + "/") else { return nil }
        let parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard !parts.contains("..") else { return nil }
        let keep: Int, owner: String
        if parts.count >= 3, parts[0] == "Library", ["Caches", "Logs"].contains(parts[1]) {
            // A protected file deeper down is a rule about that file, not its folder.
            guard reason != "protected" || parts.count == 3 else { return nil }
            (keep, owner) = (3, parts[2])
        } else if parts.count >= 7, Array(parts[0...1]) == ["Library", "Containers"], Array(parts[3...5]) == ["Data", "Library", "Caches"] {
            // One folder inside the app's caches, never the whole Caches folder.
            guard reason != "protected" || parts.count == 7 else { return nil }
            (keep, owner) = (7, parts[2])
        } else if parts.count >= 3, reason == "permission denied", Array(parts[0...1]) == [".npm", "_cacache"] {
            (keep, owner) = (3, "npm")
        } else {
            return nil
        }
        guard !keptOwners.contains(owner), !keptPrefixes.contains(where: owner.hasPrefix) else { return nil }
        return (home + "/" + parts.prefix(keep).joined(separator: "/"), owner)
    }

    private static func recentLog() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/mole/operations.log")
        guard let file = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? file.close() }
        let end = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: end > 2_000_000 ? end - 2_000_000 : 0)
        return String(decoding: (try? file.readToEnd()) ?? Data(), as: UTF8.self)
    }

    private static func displayName(_ owner: String, path: String) -> String {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        return (app ?? owner) + (path.contains("/Library/Logs/") ? "（ログ）" : "")
    }

    static func scan() -> [RemainingItem] {
        let home = NSHomeDirectory()
        var found: [String: (owner: String, admin: Bool)] = [:]
        for entry in parse(recentLog()) {
            guard let item = candidate(entry.path, reason: entry.reason, home: home) else { continue }
            found[item.path] = (item.owner, found[item.path]?.admin == true || entry.reason == "permission denied")
        }
        let manager = FileManager.default
        return found.compactMap { path, item -> RemainingItem? in
            guard manager.fileExists(atPath: path), (try? manager.destinationOfSymbolicLink(atPath: path)) == nil else { return nil }
            let bytes = FolderSize.of(path)
            guard bytes > 0 else { return nil }
            return RemainingItem(path: path, name: displayName(item.owner, path: path), owner: item.owner, bytes: bytes, needsAdmin: item.admin)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    static func shellQuoted(_ paths: [String]) -> String {
        paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    /// Root-owned leftovers; macOS asks for the password. Returns whether it ran.
    static func removeAsAdmin(_ paths: [String]) -> Bool {
        let command = "/bin/rm -rf -- " + shellQuoted(paths)
        let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(quoted)\" with administrator privileges"]
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Removes each path for good. Returns how many remain.
    static func remove(_ items: [RemainingItem]) -> Int {
        let manager = FileManager.default
        var stuck = Set(ExternalCache.remove(items.map(\.path), under: NSHomeDirectory()))
        let admin = items.filter { $0.needsAdmin && stuck.contains($0.path) }.map(\.path)
        if !admin.isEmpty, removeAsAdmin(admin) { stuck.subtract(admin.filter { !manager.fileExists(atPath: $0) }) }
        return stuck.count
    }
}

/// Listed after a clean or preview. Nothing starts selected: Mole kept these on purpose.
struct RemainingCard: View {
    /// The page's alert: a second `.alert` inside it never appears.
    @Binding var confirm: ConfirmAction?
    let refresh: Date?
    @ViewState private var items: [RemainingItem] = []
    @ViewState private var selected = Set<String>()
    @ViewState private var showAll = false
    @ViewState private var working = false
    @ViewState private var failed = 0

    private var shown: [RemainingItem] { showAll ? items : Array(items.prefix(8)) }
    private var chosen: [RemainingItem] { items.filter { selected.contains($0.id) } }

    private func running(_ owner: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return owner == id || owner.hasPrefix(id + ".")
        }
    }

    var body: some View {
        Group {
            if !items.isEmpty {
                GlowCard(glow: .ember, style: .rim, padding: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Mole が残した項目").cardTitle()
                        Text("Mole が保護した項目や、削除できなかった項目です。選んだものだけ完全に削除します。Apple のシステム用の項目は表示しません。").caption()
                        ForEach(shown) { row($0) }
                        if items.count > shown.count {
                            Button("すべて表示（\(items.count)件）") { showAll = true }.buttonStyle(.link).font(.system(size: 12))
                        }
                        if failed > 0 {
                            Text("\(failed) 項目を削除できませんでした。").font(.system(size: 12)).foregroundStyle(Theme.danger)
                        }
                        HStack {
                            Spacer()
                            Button("選んだ項目を削除") { ask() }.buttonStyle(.pill).disabled(chosen.isEmpty || working)
                        }
                    }
                }
            }
        }
        .task(id: refresh) { await reload() }
    }

    private func row(_ item: RemainingItem) -> some View {
        HStack {
            Toggle(isOn: Binding { selected.contains(item.id) } set: { on in
                if on { selected.insert(item.id) } else { selected.remove(item.id) }
            }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if item.owner == "com.spotify.client" {
                        Text("オフライン保存した音楽も消える場合があります。").caption()
                    } else if !running(item.owner).isEmpty {
                        Text("起動中です。削除するときに終了します。").caption()
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            Text(item.bytes.bytesText).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            Button("Finder で表示") { NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "") }
                .buttonStyle(.link).font(.system(size: 12))
        }
    }

    private func reload() async {
        let found = await Task.detached(priority: .utility) { Remaining.scan() }.value
        items = found
        selected.formIntersection(found.map(\.id))
    }

    private func ask() {
        let list = chosen
        let apps = Array(Set(list.flatMap { running($0.owner) }))
        let names = apps.compactMap(\.localizedName).sorted().joined(separator: "、")
        let total = list.reduce(Int64(0)) { $0 + $1.bytes }
        confirm = .init(title: "\(total.bytesText) を削除しますか？",
                        message: "\(list.count) 項目を完全に削除します。元に戻せません。"
                            + (names.isEmpty ? "" : "\(names) を終了します。")
                            + (list.contains(where: \.needsAdmin) ? "一部は管理者パスワードが必要です。" : ""),
                        button: "削除") {
            Task { await remove(list, quitting: apps) }
        }
    }

    private func remove(_ list: [RemainingItem], quitting apps: [NSRunningApplication]) async {
        working = true
        apps.forEach { $0.terminate() }
        for _ in 0..<16 where !apps.allSatisfy(\.isTerminated) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        // An app that stayed open, for example over unsaved work, keeps its cache.
        let open = list.filter { !running($0.owner).isEmpty }
        let clear = list.filter { item in !open.contains(item) }
        failed = open.count + (await Task.detached(priority: .userInitiated) { Remaining.remove(clear) }.value)
        selected = []
        working = false
        await reload()
    }
}
