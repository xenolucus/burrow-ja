import AppKit
import SwiftUI

/// Experimental: `mo clean --external` removes only OS metadata (.DS_Store, ._* files and temporary
/// folders) and refuses internal volumes. Caches there are found here instead, because Mole does
/// not look for them; they are listed unselected and only ever go to the volume's Trash.
enum ExternalDrives {
    static let enabledKey = "experimentalExternalClean"

    /// Mole then keeps .DS_Store and ._ files, so its external clean finds almost nothing.
    static var finderMetadataProtected: Bool {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mole/whitelist")
        return (try? String(contentsOf: file, encoding: .utf8))?.contains("FINDER_METADATA") ?? false
    }

    static func isCandidate(path: String, isInternal: Bool?) -> Bool {
        let parts = path.split(separator: "/")
        return isInternal == false && parts.count == 2 && parts[0] == "Volumes"
    }

    static func mounted() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            isCandidate(path: url.path, isInternal: (try? url.resourceValues(forKeys: Set(keys)))?.volumeIsInternal)
        }
    }
}

struct ExternalCache: Identifiable, Hashable {
    let path: String
    let kind: String
    let bytes: Int64
    /// Mac metadata on the whole volume, removed by Mole rather than moved to the Trash.
    var byMole = false
    var id: String { path }

    static func split(_ chosen: [ExternalCache]) -> (trash: [String], mole: [String]) {
        (chosen.filter { !$0.byMole }.map(\.path), chosen.filter(\.byMole).map(\.path))
    }
}

enum ExternalCacheScanner {
    /// Only folders an app recreates by itself. Unknown folders are never offered.
    static func kind(name: String, parent: String, siblings: Set<String>) -> String? {
        switch name {
        case "Media Cache Files", "Media Cache": "Adobe メディアキャッシュ"
        case "Peak Files": "Adobe の音声波形"
        case "Adobe Premiere Pro Video Previews": "Premiere Pro のビデオプレビュー"
        case "Adobe Premiere Pro Audio Previews": "Premiere Pro のオーディオプレビュー"
        case _ where name.hasPrefix("Disk Cache - ") || name.hasPrefix("Adobe After Effects Disk Cache"):
            "After Effects のディスクキャッシュ"
        case "DerivedData": "Xcode のビルドデータ"
        case "shadercache" where parent == "steamapps": "Steam のシェーダーキャッシュ"
        case "Library" where siblings.isSuperset(of: ["Assets", "ProjectSettings"]): "Unity のプロジェクトキャッシュ"
        default: nil
        }
    }

    /// Stays on the volume, below `depth`, and outside packages and hidden folders.
    /// shortcut: stops after `limit` seconds, a huge drive shows only what was found by then.
    static func scan(_ root: URL, depth: Int = 8, limit: TimeInterval = 30, minBytes: Int64 = 1_000_000) -> [ExternalCache] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                         errorHandler: { _, _ in true }) else { return [] }
        let started = Date()
        var matches: [(URL, String)] = []
        // Hidden, so the walker skips it. Adobe only creates it at the top of a volume.
        let adobeTemp = root.appendingPathComponent(".adobeTemp")
        if (try? adobeTemp.resourceValues(forKeys: Set(keys)))?.isDirectory == true {
            matches.append((adobeTemp, "Adobe の一時ファイル（Adobe アプリを閉じてから）"))
        }
        for case let url as URL in walker {
            if Date().timeIntervalSince(started) > limit { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if walker.level >= depth { walker.skipDescendants() }
            let parent = url.deletingLastPathComponent()
            let needsSiblings = url.lastPathComponent == "Library"
            let siblings = needsSiblings ? Set((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []) : []
            if let kind = kind(name: url.lastPathComponent, parent: parent.lastPathComponent, siblings: siblings) {
                walker.skipDescendants()
                matches.append((url, kind))
            }
        }
        // Measured after the walk, so a huge cache cannot use up the time limit. Empty previews are noise.
        return matches.map { ExternalCache(path: $0.0.path, kind: $0.1, bytes: FolderSize.of($0.0.path)) }
            .filter { $0.bytes >= minBytes }
            .sorted { $0.bytes > $1.bytes }
    }
}

struct ExternalCleanCard: View {
    let model: AppModel
    /// The page's alert: a second `.alert` inside it never appears.
    @Binding var confirm: ConfirmAction?
    @AppStorage(ExternalDrives.enabledKey) private var enabled = false
    @ViewState private var drives: [URL] = []
    @ViewState private var scanning: URL?
    /// The drive the list below belongs to; only its clean button is live.
    @ViewState private var scanned: URL?
    @ViewState private var caches: [ExternalCache]?
    @ViewState private var selected = Set<String>()
    @ViewState private var failed = 0

    private let mounts = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
    private let unmounts = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)

    var body: some View {
        if enabled {
            GlowCard(glow: .ember, style: .rim, padding: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("外付けドライブ（試験的）").cardTitle()
                    Text("アプリのキャッシュと、Mac が作る .DS_Store などを探します。選んだものだけ整理します。自分のファイルとゴミ箱には触れません。").caption()
                    if ExternalDrives.finderMetadataProtected {
                        Text("保護パスに FINDER_METADATA があるため、.DS_Store などはほとんど見つかりません。").caption()
                    }
                    if drives.isEmpty {
                        Text("外付けドライブは接続されていません。").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(drives, id: \.self) { drive in
                        HStack {
                            Text(drive.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                            Button("プレビュー") { find(drive) }.buttonStyle(.pillSecondary).disabled(scanning != nil)
                            Button("今すぐクリーン") { askClean() }.buttonStyle(.pill)
                                .disabled(scanned != drive || selected.isEmpty)
                        }
                    }
                    if let scanning {
                        Text("\(scanning.lastPathComponent) を確認しています（最大30秒）…").caption()
                    }
                    if let caches { results(caches) }
                }
            }
            .onAppear { drives = ExternalDrives.mounted() }
            .onReceive(mounts) { _ in drives = ExternalDrives.mounted() }
            .onReceive(unmounts) { _ in drives = ExternalDrives.mounted(); caches = nil; scanned = nil; selected = [] }
        }
    }

    @ViewBuilder private func results(_ caches: [ExternalCache]) -> some View {
        if caches.isEmpty {
            Text("整理できるものは見つかりませんでした。").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
        }
        ForEach(caches) { cache in
            HStack {
                Toggle(isOn: binding(cache)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cache.kind).font(.system(size: 13, weight: .medium))
                        Text(cache.path).caption().lineLimit(1).truncationMode(.middle)
                    }
                }
                .toggleStyle(.checkbox)
                Spacer()
                Text(cache.bytes.bytesText).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                if !cache.byMole {
                    Button("Finder で表示") { NSWorkspace.shared.selectFile(cache.path, inFileViewerRootedAtPath: "") }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }
        }
        if failed > 0 {
            Text("\(failed) 項目をゴミ箱に入れられませんでした。").font(.system(size: 12)).foregroundStyle(Theme.danger)
        }
        if !caches.isEmpty, selected.isEmpty {
            Text("消すものを選ぶと「今すぐクリーン」を押せます。").caption()
        }
    }

    private func binding(_ cache: ExternalCache) -> Binding<Bool> {
        Binding {
            selected.contains(cache.path)
        } set: { on in
            if on { selected.insert(cache.path) } else { selected.remove(cache.path) }
        }
    }

    private func find(_ drive: URL) {
        scanning = drive
        scanned = drive
        caches = nil
        selected = []
        failed = 0
        Task {
            var found = await Task.detached(priority: .utility) { ExternalCacheScanner.scan(drive) }.value
            // shortcut: a failed Mole preview just hides this row, the caches above still work.
            if let data = try? await Mole.capture(["clean", "--external", drive.path, "--dry-run"]) {
                let bytes = SectionReport.parse(String(decoding: data, as: UTF8.self)).total
                if bytes > 0 {
                    found.append(.init(path: drive.path, kind: "Mac の不要ファイル（.DS_Store など）", bytes: bytes, byMole: true))
                }
            }
            caches = found
            scanning = nil
        }
    }

    private func askClean() {
        let chosen = (caches ?? []).filter { selected.contains($0.path) }
        let plan = ExternalCache.split(chosen)
        let bytes = chosen.map(\.bytes).reduce(0, +).bytesText
        var message = bytes + "。"
        if !plan.trash.isEmpty { message += "キャッシュはゴミ箱に移動します。空き容量が増えるのは、ゴミ箱を空にしたあとです。" }
        if !plan.mole.isEmpty { message += "Mac の不要ファイルは Mole が完全に削除します。" }
        confirm = .init(title: "\(chosen.count) 項目をクリーンしますか？", message: message, button: "クリーン") {
            let left = Trash.move(plan.trash)
            failed = left.count
            caches = caches?.filter { !selected.contains($0.path) || left.contains($0.path) }
            selected = []
            if let volume = plan.mole.first {
                model.run("Mac の不要ファイルを削除しています", ["clean", "--external", volume])
            }
        }
    }
}

struct ExperimentalCard: View {
    @AppStorage(ExternalDrives.enabledKey) private var enabled = false

    var body: some View {
        GlowCard(glow: .ember, style: .rim, padding: 22) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("試験的な機能").cardTitle()
                    Text("外付け SSD や HDD の不要ファイルとキャッシュを整理します。予告なく変更する場合があります。").caption()
                }
                Spacer()
                Toggle("外付けドライブのクリーン", isOn: $enabled)
                    .font(.system(size: 13)).toggleStyle(.switch).controlSize(.small)
            }
        }
    }
}
