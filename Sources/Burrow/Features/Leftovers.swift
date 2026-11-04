import SwiftUI

/// What apps that are gone left in ~/Library: folders and files named after their bundle id.
struct Leftover: Identifiable, Hashable {
    enum Kind: String { case cache = "Cache", logs = "Logs", state = "Window state", web = "Web data", data = "App data", settings = "Settings" }
    struct Item: Hashable { let path: String; let kind: Kind; let bytes: Int64 }

    var id: String { bundleID }
    let bundleID: String
    let items: [Item]
    let lastUsed: Date
    /// The app itself, when it still sits in the Trash.
    var trashedApp: String?

    var bytes: Int64 { items.map(\.bytes).reduce(0, +) }
    var kinds: [Kind] { Array(Set(items.map(\.kind))).sorted { $0.rawValue < $1.rawValue } }
    var name: String {
        if let trashedApp { return ((trashedApp as NSString).lastPathComponent as NSString).deletingPathExtension }
        return Self.displayName(bundleID)
    }

    /// The most telling words of a bundle id: "com.figma.Desktop" → "Figma Desktop",
    /// "com.netease.mumu.nemux-global" → "Nemux Global", "com.tw93.MoleApp" → "MoleApp".
    static func displayName(_ id: String) -> String {
        let parts = id.split(separator: ".").map(String.init)
        let generic: Set<String> = ["app", "desktop", "mac", "macos", "client", "helper", "emulator", "agent", "launcher"]
        var words = [parts.last ?? id]
        if generic.contains(words[0].lowercased()) || words[0].count <= 3, parts.count >= 3 {
            words.insert(parts[parts.count - 2], at: 0)
        }
        return words.joined(separator: " ")
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The symbol for the kind of data that takes most of the space.
    var symbol: String {
        switch items.first?.kind {
        case .web: "globe"
        case .logs: "doc.text"
        case .settings: "gearshape"
        case .data: "folder"
        case .state: "macwindow"
        default: "archivebox"
        }
    }
}

/// Finds leftovers the way Mole's `clean` does: entries named after a bundle id whose app is
/// gone, never what Mole's own `should_protect_data` protects, never a user-protected path.
/// Two differences: caches show after a week unused instead of Mole's 30 days (anything
/// touched in the last week still has a user, often a command-line tool), and an app waiting in
/// the Trash shows at once. Only regenerable data is offered (caches, logs, window state, web
/// data); an app's data and settings only when that very app is in the Trash, which proves whose
/// they are. A vendor with any app still installed keeps everything: helpers share its prefix.
enum LeftoverScanner {
    static let places: [(String, Leftover.Kind)] = [
        ("Library/Caches", .cache), ("Library/Logs", .logs), ("Library/Saved Application State", .state),
        ("Library/HTTPStorages", .web), ("Library/WebKit", .web),
        ("Library/Application Support", .data), ("Library/Preferences", .settings),
    ]
    static let prefixes: Set<String> = ["com", "org", "net", "io", "app", "dev", "ai", "co", "me"]
    /// Mole's never-delete name patterns (`ORPHAN_NEVER_DELETE_PATTERNS`).
    static let never = ["password", "keychain", "bitwarden", "lastpass", "keepass", "dashlane", "enpass",
                        "ssh", "gpg", "gnupg"]
    static let unusedFor: TimeInterval = 7 * 86400

    /// "com.foo.Bar", "com.foo.Bar.savedState", "com.foo.Bar.plist" → "com.foo.Bar".
    nonisolated static func bundleID(fromEntry name: String) -> String? {
        var id = name
        for ext in [".savedState", ".plist", ".binarycookies"] where id.hasSuffix(ext) { id = String(id.dropLast(ext.count)) }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }), prefixes.contains(parts[0].lowercased()),
              id.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { return nil }
        return id
    }

    /// Whether `id` may still belong to something on this Mac. `installed` is lowercased.
    nonisolated static func inUse(_ id: String, installed: Set<String>) -> Bool {
        let lower = id.lowercased()
        if lower.hasPrefix("com.apple.") || never.contains(where: lower.contains) { return true }
        let vendor = lower.split(separator: ".").prefix(2).joined(separator: ".") + "."
        return installed.contains { $0 == lower || $0.hasPrefix(vendor) }
    }

    /// Whether removing `path` would touch a protected entry: the entry itself, a folder above it,
    /// or anything inside it (`~/x/com.foo/keep.db` protects `~/x/com.foo`). As in Mole, `*` also
    /// crosses folders.
    nonisolated static func isProtected(_ path: String, by patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        func matches(_ s: String) -> Bool { patterns.contains { fnmatch($0, s, 0) == 0 } }
        var up = path
        while up.count > 1 {
            if matches(up) { return true }
            up = (up as NSString).deletingLastPathComponent
        }
        // A pattern for what lies inside the entry (`…/com.foo/*`, `…/com.foo/keep.db`), even if nothing matches yet.
        if matches(path + "/*") || patterns.contains(where: { String($0.prefix { !"*?[".contains($0) }).hasPrefix(path + "/") }) {
            return true
        }
        // Walk the entry only for globs that could reach inside it (`~/*/keep.db`).
        let globs = patterns.filter { p in
            let fixed = String(p.prefix { !"*?[".contains($0) })
            return fixed.count < p.count && path.hasPrefix(fixed)
        }
        guard !globs.isEmpty, let inside = FileManager.default.enumerator(atPath: path) else { return false }
        for case let sub as String in inside where globs.contains(where: { fnmatch($0, path + "/" + sub, 0) == 0 }) { return true }
        return false
    }

    /// Mole's protection rules (`~/.config/mole/whitelist`) as absolute patterns; nil when the
    /// file exists but cannot be read, so nothing is offered rather than something protected.
    nonisolated static func protectedPatterns() -> [String]? {
        let url = ConfigList.whitelist.url
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard (try? String(contentsOf: url, encoding: .utf8)) != nil else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ConfigList.whitelist.read().map {
            var p = ($0.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
                     as NSString).expandingTildeInPath
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            return p
        }
    }

    /// The ids Mole's own `should_protect_data` keeps (Authy, YubiKey, developer tools, input
    /// methods, VPNs…), asked from the bundled Mole so both always agree. nil if Mole could not
    /// answer, and then nothing is offered.
    nonisolated static func protectedByMole(_ ids: [String]) -> Set<String>? {
        guard !ids.isEmpty else { return [] }
        let script = #"source "$1/lib/core/app_protection.sh" || exit 3; declare -F should_protect_data >/dev/null || exit 4; shift; for id in "$@"; do should_protect_data "$id" && echo "$id"; done; echo __done__"#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script, "burrow", Mole.root.path] + ids
        p.environment = Mole.environment(tty: false)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard p.terminationStatus == 0, lines.last == "__done__" else { return nil }
        return Set(lines.dropLast())
    }

    /// `justRemoved`: lowercased ids of apps deleted while Burrow was watching; like an app in
    /// the Trash, their settings and data count at once.
    nonisolated static func scan(justRemoved: Set<String> = []) -> [Leftover] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        guard let protected = protectedPatterns() else { return [] }
        guard let installed = installedIDs() else { return [] }
        let trashed = trashedApps()
        var found: [String: [Leftover.Item]] = [:]
        var used: [String: Date] = [:]
        for (place, kind) in places {
            let dir = home.appendingPathComponent(place)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names {
                guard let id = bundleID(fromEntry: name), !inUse(id, installed: installed) else { continue }
                let inTrash = trashed[id.lowercased()] != nil || justRemoved.contains(id.lowercased())
                if kind == .data || kind == .settings, !inTrash { continue }
                let path = dir.appendingPathComponent(name).path
                // A link may lead to live data elsewhere; an unreadable date proves nothing.
                guard !isProtected(path, by: protected),
                      let attrs = try? fm.attributesOfItem(atPath: path), attrs[.type] as? FileAttributeType != .typeSymbolicLink,
                      let modified = attrs[.modificationDate] as? Date,
                      inTrash || Date().timeIntervalSince(modified) >= unusedFor else { continue }
                found[id, default: []].append(.init(path: path, kind: kind, bytes: FolderSize.of(path)))
                used[id] = max(used[id] ?? .distantPast, modified)
            }
        }
        guard let moleKeeps = protectedByMole(Array(found.keys)) else { return [] }
        return found.compactMap { id, items in
            if moleKeeps.contains(id) { return nil }
            // A last check with LaunchServices catches apps outside the folders Spotlight sees.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
               !url.path.contains("/.Trash/"), fm.fileExists(atPath: url.path) { return nil }
            return Leftover(bundleID: id, items: items.sorted { $0.bytes > $1.bytes }, lastUsed: used[id] ?? .distantPast,
                            trashedApp: trashed[id.lowercased()])
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Bundle ids of every app Spotlight knows (all indexed volumes), in the usual folders and
    /// running now, lowercased. Apps in the Trash do not count. nil when Spotlight did not answer
    /// in time or had no answer, and then nothing is offered.
    nonisolated static func installedIDs() -> Set<String>? {
        let fm = FileManager.default
        var ids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        let mdfind = Process()
        mdfind.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        mdfind.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
        let out = Pipe()
        mdfind.standardOutput = out
        mdfind.standardError = FileHandle.nullDevice
        guard (try? mdfind.run()) != nil else { return nil }
        let pid = mdfind.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if mdfind.isRunning { kill(pid, SIGKILL) } }
        let paths = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        mdfind.waitUntilExit()
        // A stalled, failed or empty answer (indexing off) cannot rule out apps elsewhere.
        guard mdfind.terminationReason == .exit, mdfind.terminationStatus == 0, !paths.isEmpty else { return nil }
        for path in paths where !path.contains("/.Trash/") {
            if let id = Bundle(path: String(path))?.bundleIdentifier { ids.insert(id.lowercased()) }
        }
        let roots = ["/Applications", "/System/Applications", "/Library/Application Support",
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").path]
        for root in roots {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in e {
                if e.level > 4 { e.skipDescendants(); continue }
                guard url.pathExtension == "app" else { continue }
                if let id = Bundle(url: url)?.bundleIdentifier { ids.insert(id.lowercased()) }
            }
        }
        return ids
    }

    /// Apps waiting in the Trash, by bundle id (lowercased): their name and icon still help.
    /// Reading the Trash needs Full Disk Access; without it the list is empty.
    nonisolated static func trashedApps() -> [String: String] {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []
        var out: [String: String] = [:]
        for name in names where name.hasSuffix(".app") {
            let path = trash.appendingPathComponent(name).path
            if let id = Bundle(path: path)?.bundleIdentifier { out[id.lowercased()] = path }
        }
        return out
    }
}

@MainActor
final class LeftoverStore: ObservableObject {
    @Published var leftovers: [Leftover]?
    @Published var scanning = false
    private(set) var checkedAt: Date?
    var onBusyChange: ((Bool) -> Void)?

    private var loadTask: Task<Void, Never>?
    private var appsSeen: [String: String]?
    /// Apps deleted while Burrow watched, confirmed in the Trash: lowercased bundle id → where
    /// the app was. Cleared again when the app comes back.
    private(set) var removed: [String: String] = [:]

    /// Apps in the app folders (one vendor folder deep) and the Trash, path → lowercased bundle
    /// id: when this changes, an app was installed or deleted.
    nonisolated static func apps() -> [String: String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var out: [String: String] = [:]
        func add(_ dir: String, nested: Bool) {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir + "/" + name
                if name.hasSuffix(".app") {
                    out[path] = Bundle(path: path)?.bundleIdentifier?.lowercased() ?? ""
                } else if nested, !name.hasPrefix(".") {
                    add(path, nested: false)
                }
            }
        }
        add("/Applications", nested: true)
        add(home + "/Applications", nested: true)
        add(home + "/.Trash", nested: false)
        return out
    }

    /// The first look, taken when watching starts, so a deletion during the launch scan counts.
    func watchApps() {
        if appsSeen == nil { appsSeen = Self.apps() }
    }

    /// Looks again as soon as an app was deleted (or added), so its leftovers show up without
    /// waiting for a relaunch.
    func refreshIfAppsChanged() async {
        guard let seen = appsSeen else { return }
        let now = await Task.detached { LeftoverStore.apps() }.value
        guard now != seen else { return }
        appsSeen = now
        let stillThere = Set(now.filter { !$0.key.contains("/.Trash/") }.values)
        removed = removed.filter { !stillThere.contains($0.key) }
        var gone = Self.removedApps(seen: seen, now: now)
        if !gone.isEmpty, !Self.trashReadable {
            // Without Full Disk Access (it drops when an update changes the ad-hoc signature) the
            // Trash cannot be checked: an app still missing a few seconds later counts as deleted,
            // which rules out an updater swapping the bundle.
            try? await Task.sleep(for: .seconds(4))
            let later = await Task.detached { LeftoverStore.apps() }.value
            let back = Set(later.filter { !$0.key.contains("/.Trash/") }.values)
            gone = gone.filter { !back.contains($0.key) }
        } else {
            gone = gone.filter { Self.inTrash($0.key, formerPath: $0.value, now: now) }
        }
        for (id, path) in gone { removed[id] = path }
        // A scan that started before this change cannot know about it: wait for it, then look again.
        if loadTask != nil { await load() }
        await load()
    }

    /// Apps that left the app folders between two looks (id → where they were). A renamed or
    /// re-downloaded app still in an app folder does not count.
    nonisolated static func removedApps(seen: [String: String], now: [String: String]) -> [String: String] {
        let stillThere = Set(now.filter { !$0.key.contains("/.Trash/") }.values)
        var out: [String: String] = [:]
        for (path, id) in seen where now[path] == nil && !id.isEmpty && !path.contains("/.Trash/") && !stillThere.contains(id) {
            out[id] = path
        }
        return out
    }

    /// Listing the Trash needs Full Disk Access.
    nonisolated static var trashReadable: Bool {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        return (try? FileManager.default.contentsOfDirectory(atPath: trash)) != nil
    }

    /// Only an app the user put in the Trash counts as deleted: an updater that swaps the bundle
    /// or a move to another disk leaves a gap, never a copy in the Trash. Listing the Trash needs
    /// Full Disk Access, so the app's own name there is checked too.
    nonisolated static func inTrash(_ id: String, formerPath: String, now: [String: String]) -> Bool {
        if now.contains(where: { $0.key.contains("/.Trash/") && $0.value == id }) { return true }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            .appendingPathComponent((formerPath as NSString).lastPathComponent).path
        return Bundle(path: path)?.bundleIdentifier?.lowercased() == id
    }

    /// A second caller (a Rescan during the launch scan, the refresh after trashing) waits for
    /// the scan already running instead of being dropped.
    func load() async {
        if let loadTask { return await loadTask.value }
        // The task clears itself, so a caller resuming late never joins a finished scan.
        let task = Task { await scan(); loadTask = nil }
        loadTask = task
        await task.value
    }

    private func scan() async {
        scanning = true
        onBusyChange?(true)
        let removed = Set(removed.keys)
        leftovers = await Task.detached { LeftoverScanner.scan(justRemoved: removed) }.value
        checkedAt = Date()
        scanning = false
        onBusyChange?(false)
    }

    /// Moves what is still a leftover to the Trash: a fresh scan with every rule (installed and
    /// running apps, LaunchServices, protected paths, age) must still offer each item.
    /// Returns the paths that could not be moved.
    func trash(_ chosen: [Leftover]) async -> [String] {
        let removed = Set(removed.keys)
        let failed = await Task.detached {
            let still = Set(LeftoverScanner.scan(justRemoved: removed).flatMap(\.items).map(\.path))
            return Trash.move(chosen.flatMap(\.items).map(\.path).filter(still.contains))
        }.value
        // A scan already running started before the move: wait for it, then look again.
        if loadTask != nil { await load() }
        await load()
        return failed
    }
}

struct LeftoversView: View {
    @ObservedObject var store: LeftoverStore
    @ViewState private var selected = Set<String>()
    @ViewState private var confirm: ConfirmAction?
    @ViewState private var failed: [String] = []

    private var all: [Leftover] { store.leftovers ?? [] }
    private var chosen: [Leftover] { all.filter { selected.contains($0.id) } }
    private var allSelected: Bool { !selected.isEmpty && selected.count == all.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HeroCard(glow: .ember, label: "Leftovers of removed apps", bytes: store.leftovers.map { $0.map(\.bytes).reduce(0, +) },
                     detail: (store.leftovers.map { "\($0.count) app\($0.count == 1 ? " that is" : "s that are") gone left files behind. " } ?? "")
                        + "Caches, logs and web data unused for a week; settings and data too while the app is in the Trash or was just deleted. Everything goes to the Trash.",
                     scanning: store.scanning, progress: "Looking through your Library", checked: store.checkedAt) {
                Button("Rescan") { Task { await store.load() } }.buttonStyle(.pillSecondary).disabled(store.scanning)
                    .keyboardShortcut("r", modifiers: .command)
                Button(allSelected ? "Select none" : "Select all") {
                    selected = allSelected ? [] : Set(all.map(\.id))
                }
                .buttonStyle(.pillSecondary)
                .disabled(all.isEmpty)
            }

            if !failed.isEmpty {
                Label("\(failed.count) item\(failed.count == 1 ? "" : "s") could not be moved to the Trash.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.danger)
            }

            if let leftovers = store.leftovers, leftovers.isEmpty {
                EmptyState(symbol: "checkmark.seal", text: "No leftovers of removed apps.")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14)], spacing: 14) {
                ForEach(all) { left in
                    SelectTile(selected: selected.contains(left.id), glow: .ember) { toggle(left) } content: {
                        if let app = left.trashedApp {
                            AppIcon(path: app, size: 38)
                        } else {
                            Image(systemName: left.symbol).font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Glow.ember.color)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(Glow.ember.color.opacity(0.14)))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(left.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(left.bundleID).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.tertiaryText).lineLimit(1).truncationMode(.middle)
                            Text("Changed \(left.lastUsed.formatted(.relative(presentation: .named))) · \(left.kinds.map(\.rawValue).joined(separator: ", "))")
                                .caption().lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(left.bytes.bytesText).font(.system(size: 12)).monospacedDigit()
                            .frame(width: 78, alignment: .trailing)
                    }
                    .contextMenu {
                        Text(left.bundleID)
                        ForEach(left.items, id: \.path) { item in
                            Button("Show \(item.kind.rawValue.lowercased()) in Finder") {
                                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                            }
                        }
                    }
                }
            }
        }
        .bottomBar(!selected.isEmpty) {
            SelectionBar(glow: .ember, title: "\(chosen.count) app\(chosen.count == 1 ? "" : "s") · \(chosen.map(\.bytes).reduce(0, +).bytesText)",
                         subtitle: "Their leftovers go to the Trash, so you can put them back.", clear: { selected.removeAll() }) {
                Button("Move to Trash") { askToTrash() }.buttonStyle(.pill)
            }
        }
        .confirmation($confirm)
        .onAppear { if store.leftovers == nil { Task { await store.load() } } }
        .onChange(of: store.leftovers) { selected.formIntersection(Set(all.map(\.id))) }
    }

    private func toggle(_ left: Leftover) {
        if selected.contains(left.id) { selected.remove(left.id) } else { selected.insert(left.id) }
    }

    private func askToTrash() {
        let items = chosen.flatMap(\.items).count
        confirm = .init(title: "Move what \(chosen.count) removed app\(chosen.count == 1 ? "" : "s") left to the Trash?",
                        message: "\(items) item\(items == 1 ? "" : "s"), \(chosen.map(\.bytes).reduce(0, +).bytesText). You can restore them from the Trash.",
                        button: "Move to Trash") {
            let picked = chosen
            selected.removeAll()
            Task { failed = await store.trash(picked) }
        }
    }
}
