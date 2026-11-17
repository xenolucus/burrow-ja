import AppKit
import SwiftUI

/// Large folders that macOS counts as "System Data" and Mole does not clean.
/// Only fixed paths are offered; anything holding the user's own files is shown with a hint instead.
enum SystemData {
    struct Entry {
        let name: String
        /// Starts with "~/" for the home folder, otherwise absolute.
        let path: String
        let owner: String
        var note: String? = nil
        /// Removable only while this app is gone. Otherwise shown with `installedNote`.
        var orphanOf: String? = nil
        var installedNote: String? = nil
    }

    /// Smaller folders are not worth a row.
    static let minimumBytes: Int64 = 500_000_000

    static let entries: [Entry] = [
        Entry(name: "Steam のシェーダーキャッシュ", path: "~/Library/Application Support/Steam/steamapps/shadercache",
              owner: "com.valvesoftware.steam", note: "ゲームの初回起動時に作り直します。"),
        Entry(name: "Adobe メディアキャッシュ", path: "~/Library/Application Support/Adobe/Common/Media Cache Files", owner: "com.adobe"),
        Entry(name: "Adobe メディアキャッシュの索引", path: "~/Library/Application Support/Adobe/Common/Media Cache", owner: "com.adobe"),
        Entry(name: "uv のキャッシュ", path: "~/.cache/uv", owner: ""),
        Entry(name: "Premiere Pro (Beta) のデータ", path: "/Library/Application Support/Adobe/Premiere Pro (Beta)", owner: "com.adobe",
              orphanOf: "/Applications/Adobe Premiere Pro (Beta)", installedNote: "Creative Cloud で Beta 版をアンインストールすると消えます。"),
        Entry(name: "Premiere Pro (Beta) の設定", path: "~/Library/Application Support/Adobe/Premiere Pro (Beta)", owner: "com.adobe",
              orphanOf: "/Applications/Adobe Premiere Pro (Beta)", installedNote: "Creative Cloud で Beta 版をアンインストールすると消えます。"),
        Entry(name: "Media Encoder (Beta) のデータ", path: "/Library/Application Support/Adobe/Adobe Media Encoder (Beta)", owner: "com.adobe",
              orphanOf: "/Applications/Adobe Media Encoder (Beta)", installedNote: "Creative Cloud で Beta 版をアンインストールすると消えます。"),
    ]

    static func expand(_ path: String, home: String) -> String {
        path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }

    static func item(_ entry: Entry, home: String, exists: (String) -> Bool, size: (String) -> Int64) -> RemainingItem? {
        let path = expand(entry.path, home: home)
        guard exists(path) else { return nil }
        let bytes = size(path)
        guard bytes >= minimumBytes else { return nil }
        let installed = entry.orphanOf.map(exists) ?? false
        return RemainingItem(path: path, name: entry.name, owner: entry.owner, bytes: bytes,
                             needsAdmin: !path.hasPrefix(home + "/"),
                             note: installed ? entry.installedNote : entry.note, removable: !installed)
    }

    /// Phone and cloud copies under ~/Library/CloudStorage. Only the provider can drop them safely, through Finder.
    static func cloudCopies(home: String, size: (String) -> Int64) -> [RemainingItem] {
        let root = home + "/Library/CloudStorage"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.compactMap { name in
            let path = root + "/" + name
            let bytes = size(path)
            guard bytes >= minimumBytes else { return nil }
            return RemainingItem(path: path, name: name + " のダウンロード済みファイル", owner: "", bytes: bytes, needsAdmin: false,
                                 note: "Finder で右クリックし「ダウンロードを削除」を選ぶと空きます。元のファイルは消えません。", removable: false)
        }
    }

    static func scan() -> [RemainingItem] {
        let home = NSHomeDirectory(), manager = FileManager.default
        let exists = { (path: String) in
            manager.fileExists(atPath: path) && (try? manager.destinationOfSymbolicLink(atPath: path)) == nil
        }
        return (entries.compactMap { item($0, home: home, exists: exists, size: FolderSize.of) }
                + cloudCopies(home: home, size: FolderSize.of))
            .sorted { $0.bytes > $1.bytes }
    }
}

/// One row of the breakdown: what macOS lumps into "System Data", grouped by where it lives.
struct SystemDataPart: Sendable {
    let name: String
    /// Folders whose direct children are measured. "~/" means the home folder.
    let roots: [String]
    var exclude: [String] = []
    var hint: String = ""
    /// Outside the home folder, shared by every account on this Mac.
    var shared = false

    static let all: [SystemDataPart] = [
        .init(name: "Steam（ゲームと MOD）", roots: ["~/Library/Application Support/Steam"],
              hint: "MOD は Steam で購読を解除すると消えます。"),
        .init(name: "スマホ・クラウドのコピー", roots: ["~/Library/Application Support/FileProvider"],
              hint: "Finder の「場所」で右クリックし「ダウンロードを削除」を選ぶと空きます。"),
        .init(name: "アプリのデータ", roots: ["~/Library/Application Support"],
              exclude: ["~/Library/Application Support/Steam", "~/Library/Application Support/FileProvider"],
              hint: "使わないアプリは「アンインストール」で関連ファイルごと消せます。"),
        .init(name: "キャッシュ", roots: ["~/Library/Caches"], hint: "「クリーン」で消せます。消しても作り直されます。"),
        .init(name: "アプリの保管庫", roots: ["~/Library/Containers", "~/Library/Group Containers"],
              hint: "書類や録音などを含むので、中身を確かめてから整理してください。"),
        .init(name: "開発ツール", roots: ["~/.lmstudio", "~/.cache", "~/.npm", "~/.gradle", "~/.cargo", "~/.rustup", "~/.ollama",
                                     "~/.docker", "~/Library/Android", "~/Library/Developer"],
              hint: "SDK やモデルは再ダウンロードできます。「プロジェクト」も参考にしてください。"),
        .init(name: "ログ", roots: ["~/Library/Logs"], hint: "「クリーン」で消せます。"),
        .init(name: "全ユーザー共通のアプリデータ", roots: ["/Library/Application Support", "/Library/Developer"],
              hint: "アプリをアンインストールすると消えます。", shared: true),
        .init(name: "macOS の追加データ", roots: ["/System/Library/AssetsV2"],
              hint: "音声入力や辞書などで、macOS が管理します。", shared: true),
        .init(name: "一時ファイルとスリープ", roots: ["/private/var/folders", "/private/var/vm"],
              hint: "macOS が管理します。再起動で一部が減ります。", shared: true),
    ]
}

struct SystemDataSize: Identifiable, Sendable {
    let part: SystemDataPart
    let bytes: Int64
    /// The biggest children, for the "mostly" line.
    let top: [(name: String, bytes: Int64)]
    var id: String { part.name }
}

extension SystemData {
    static func measure(_ part: SystemDataPart, home: String,
                        children: (String) -> [String], size: (String) -> Int64) -> SystemDataSize {
        let skip = Set(part.exclude.map { expand($0, home: home) })
        var found: [(name: String, bytes: Int64)] = []
        for root in part.roots.map({ expand($0, home: home) }) {
            for child in children(root) where !skip.contains(root + "/" + child) {
                found.append((child, size(root + "/" + child)))
            }
        }
        let top = found.filter { $0.bytes >= minimumBytes }.sorted { $0.bytes > $1.bytes }.prefix(3)
        return SystemDataSize(part: part, bytes: found.reduce(0) { $0 + $1.bytes }, top: Array(top))
    }

    static func measureAll() async -> [SystemDataSize] {
        await withTaskGroup(of: SystemDataSize.self) { group in
            for part in SystemDataPart.all {
                group.addTask {
                    measure(part, home: NSHomeDirectory(),
                            children: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
                            size: FolderSize.of)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }.sorted { $0.bytes > $1.bytes }
        }
    }
}

struct SystemDataPage: View {
    @ViewState private var sizes: [SystemDataSize] = []
    @ViewState private var measuring = false

    private var largest: Int64 { max(sizes.first?.bytes ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GlowCard(glow: .blue, style: .rim, padding: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(sizes.isEmpty ? "システムデータの内訳" : "測った合計 \(sizes.reduce(Int64(0)) { $0 + $1.bytes }.bytesText)").cardTitle()
                        Spacer()
                        if measuring { ProgressView().controlSize(.small) }
                        Button(sizes.isEmpty ? "測る" : "測り直す") { Task { await reload() } }
                            .buttonStyle(.pillSecondary).disabled(measuring)
                    }
                    Text("設定の「ストレージ」は、アプリ・書類・写真などに分けられなかった残りを「システムデータ」にまとめます。その大部分を場所ごとに測ります。設定の数字とは分け方が違うので、ぴったりは一致しません。Time Machine のローカルスナップショットと、自動で空く容量は含みません。").caption()
                }
            }
            ForEach(sizes) { row($0) }
        }
        .task { if sizes.isEmpty { await reload() } }
    }

    private func row(_ size: SystemDataSize) -> some View {
        GlowCard(glow: size.part.shared ? .graphite : .blue, style: .rim, padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(size.part.name).font(.system(size: 13, weight: .medium))
                    if size.part.shared { Text("Mac 全体").caption() }
                    Spacer()
                    Text(size.bytes.bytesText).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                GeometryReader { proxy in
                    Capsule().fill(Theme.hairline)
                        .overlay(alignment: .leading) {
                            Capsule().fill(size.part.shared ? Theme.secondaryText : Theme.accent)
                                .frame(width: max(4, proxy.size.width * CGFloat(Double(size.bytes) / Double(largest))))
                        }
                }
                .frame(height: 8)
                if !size.top.isEmpty {
                    Text("主な中身: " + size.top.map { "\($0.name) \($0.bytes.bytesText)" }.joined(separator: "、")).caption().lineLimit(2)
                }
                HStack {
                    Text(size.part.hint).caption()
                    Spacer()
                    Button("Finder で表示") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: SystemData.expand(size.part.roots[0], home: NSHomeDirectory()))
                    }
                    .buttonStyle(.link).font(.system(size: 12))
                }
            }
        }
    }

    private func reload() async {
        measuring = true
        sizes = await SystemData.measureAll()
        measuring = false
    }
}
