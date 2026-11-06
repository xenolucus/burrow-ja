import AppKit
import CryptoKit
import SwiftUI

struct DuplicateFile: Identifiable, Hashable, Sendable {
    let path: String
    let bytes: Int64
    let modified: Date
    var id: String { path }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let files: [DuplicateFile]
    var id: String { files[0].path }
    var bytes: Int64 { files[0].bytes }
    var extra: Int64 { bytes * Int64(files.count - 1) }
}

/// Groups whose copies sit in exactly the same folders, so one choice settles them all.
struct DuplicateFolderSet: Identifiable, Hashable, Sendable {
    let folders: [String]
    let groups: [DuplicateGroup]
    var id: String { folders.joined(separator: "\n") }
    var extra: Int64 { groups.reduce(0) { $0 + $1.extra } }
}

enum DuplicateFinder {
    static let minBytes: Int64 = 1_000_000
    /// Tool output, where matching files are expected and removing one breaks a project.
    private static let skipped: Set<String> = ["node_modules", "Pods", "DerivedData", "Library", "build", "dist", "venv", "target"]

    private static func hash(_ path: String) -> SHA256.Digest? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        var hasher = SHA256()
        while !Task.isCancelled {
            do {
                // nil, not empty data, marks the end of the file.
                guard let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty else { return hasher.finalize() }
                hasher.update(data: chunk)
            } catch {
                return nil
            }
        }
        return nil
    }

    static func scan(_ roots: [URL]) -> [DuplicateGroup] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .volumeIdentifierKey,
                                      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var bySize: [Int64: [DuplicateFile]] = [:]
        var seen = Set<[NSObject]>()  // a hard link is one file, however many names it has
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if Task.isCancelled { return [] }
                if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let size = values.fileSize, Int64(size) >= minBytes,
                      // Hashing a file that lives in iCloud would download it.
                      values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current else { continue }
                // An identifier means something only within its volume, and some drive formats have none.
                if let file = values.fileResourceIdentifier as? NSObject, let volume = values.volumeIdentifier as? NSObject,
                   !seen.insert([volume, file]).inserted { continue }
                bySize[Int64(size), default: []].append(.init(path: url.path, bytes: Int64(size), modified: values.contentModificationDate ?? .distantPast))
            }
        }
        var groups: [DuplicateGroup] = []
        for files in bySize.values where files.count > 1 {
            let same = Dictionary(grouping: files.compactMap { file in hash(file.path).map { ($0, file) } }, by: { $0.0 })
            groups += same.values.filter { $0.count > 1 }.map { matches in
                DuplicateGroup(files: matches.map { $0.1 }.sorted { $0.modified > $1.modified })
            }
        }
        return groups.sorted { $0.extra > $1.extra }
    }

    /// Everything but the newest file of each group.
    static func allButNewest(_ groups: [DuplicateGroup]) -> Set<String> {
        Set(groups.flatMap { $0.files.dropFirst().map(\.path) })
    }

    private static func inDownloads(_ file: DuplicateFile, home: String) -> Bool { file.path.hasPrefix(home + "/Downloads/") }

    /// Downloads are the copies to lose: all of them when one exists elsewhere, else all but the newest.
    static func downloadsRule(_ groups: [DuplicateGroup], home: String) -> Set<String> {
        Set(groups.flatMap { group -> [String] in
            let downloads = group.files.filter { inDownloads($0, home: home) }
            guard !downloads.isEmpty else { return [] }
            return (downloads.count == group.files.count ? Array(downloads.dropFirst()) : downloads).map(\.path)
        })
    }

    /// Folder choices for what the Downloads rule leaves open. One pair of files is quicker to tick by hand.
    static func folderSets(_ groups: [DuplicateGroup], home: String) -> [DuplicateFolderSet] {
        let open = groups.filter { group in !group.files.contains { inDownloads($0, home: home) } }
        return Dictionary(grouping: open) { Set($0.files.map(\.folder)) }
            .filter { $0.key.count > 1 && $0.value.count > 1 }
            .map { DuplicateFolderSet(folders: $0.key.sorted(), groups: $0.value) }
            .sorted { $0.extra > $1.extra }
    }

    /// Selects every copy outside `folder`, and any second copy inside it.
    static func keeping(_ folder: String, in set: DuplicateFolderSet) -> Set<String> {
        Set(set.groups.flatMap { group -> [String] in
            let kept = group.files.first { $0.folder == folder }?.path
            return group.files.map(\.path).filter { $0 != kept }
        })
    }

    /// Choosing this file must leave at least one copy in its group.
    static func canSelect(_ path: String, in group: DuplicateGroup, selected: Set<String>) -> Bool {
        group.files.contains { $0.path != path && !selected.contains($0.path) }
    }
}

struct DuplicatesPage: View {
    private static let foldersKey = "duplicateFolders"
    @AppStorage(foldersKey) private var saved = ""
    @ViewState private var groups: [DuplicateGroup]?
    @ViewState private var selected = Set<String>()
    @ViewState private var scanTask: Task<Void, Never>?
    @ViewState private var confirm: ConfirmAction?
    @ViewState private var failed = 0
    @ViewState private var limit = 30
    @ViewState private var drives: [URL] = []
    @ViewState private var chosenDrives = Set<URL>()
    @ViewState private var keptFolders: [String: String] = [:]

    private var folders: [String] {
        let list = saved.split(separator: "\n").map(String.init)
        return list.isEmpty ? ["~/Downloads", "~/Desktop", "~/Documents"] : list
    }
    private let mounts = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
    private let unmounts = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)

    private var chosen: [DuplicateFile] { (groups ?? []).flatMap(\.files).filter { selected.contains($0.path) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GlowCard(glow: .blue, style: .rim, padding: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("探す場所").cardTitle()
                        Spacer()
                        Button("フォルダを追加") { add() }.buttonStyle(.link).font(.system(size: 12))
                    }
                    ForEach(folders, id: \.self) { folder in
                        HStack {
                            Text(folder).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("外す") { saved = folders.filter { $0 != folder }.joined(separator: "\n") }
                                .buttonStyle(.link).font(.system(size: 12)).disabled(folders.count == 1)
                        }
                    }
                    ForEach(drives, id: \.self) { drive in
                        Toggle("\(drive.lastPathComponent)（外付けドライブ）", isOn: Binding { chosenDrives.contains(drive) } set: { on in
                            if on { chosenDrives.insert(drive) } else { chosenDrives.remove(drive) }
                        })
                        .font(.system(size: 13)).toggleStyle(.checkbox)
                    }
                    if !chosenDrives.isEmpty {
                        Text("外付けドライブ全体を比べるので時間がかかることがあります。ゴミ箱に入れた分は、そのドライブのゴミ箱を空にすると空きます。").caption()
                    }
                    Text("1 MB 以上のファイルの中身を比べます。隠しファイル、アプリの中、node_modules などは対象外です。iCloud に置いたままのファイルも比べません。").caption()
                    HStack {
                        Spacer()
                        Button(scanTask == nil ? "探す" : "中止") { scanTask == nil ? start() : stop() }.buttonStyle(.pill)
                    }
                }
            }
            if scanTask != nil {
                Text("ファイルを比べています…").caption()
            } else if let groups {
                results(groups)
            }
        }
        .confirmation($confirm)
        .onAppear { drives = ExternalDrives.mounted() }
        .onReceive(mounts) { _ in drives = ExternalDrives.mounted() }
        .onReceive(unmounts) { _ in
            drives = ExternalDrives.mounted()
            chosenDrives.formIntersection(drives)
        }
    }

    @ViewBuilder private func results(_ groups: [DuplicateGroup]) -> some View {
        if groups.isEmpty {
            EmptyState(symbol: "doc.on.doc", text: "重複は見つかりませんでした。", detail: "")
        } else {
            HStack {
                Text("\(groups.count) 組の重複。\(chosen.count) 項目、\(chosen.reduce(Int64(0)) { $0 + $1.bytes }.bytesText) を選択中")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("残りは新しいものを残す") { selectRest(groups) }.buttonStyle(.pillSecondary)
                Button("ゴミ箱に入れる") { ask() }.buttonStyle(.pill).disabled(selected.isEmpty)
            }
            Text("ダウンロードにあるものは、最初から選択しています。").caption()
            ForEach(DuplicateFinder.folderSets(groups, home: NSHomeDirectory())) { folderSet($0) }
            if failed > 0 {
                Text("\(failed) 項目をゴミ箱に入れられませんでした。").font(.system(size: 12)).foregroundStyle(Theme.danger)
            }
            ForEach(groups.prefix(limit)) { card($0) }
            if groups.count > limit {
                Button("さらに表示") { limit += 30 }.buttonStyle(.link).font(.system(size: 12))
            }
        }
    }

    private func folderSet(_ set: DuplicateFolderSet) -> some View {
        GlowCard(glow: .sage, style: .rim, padding: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("同じフォルダどうしの重複 \(set.groups.count) 組（\(set.extra.bytesText)）").font(.system(size: 13, weight: .semibold))
                Text("残すフォルダを選ぶと、ほかのフォルダのコピーをまとめて選択します。").caption()
                ForEach(set.folders, id: \.self) { folder in
                    HStack {
                        Text((folder as NSString).abbreviatingWithTildeInPath).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(keptFolders[set.id] == folder ? "残します" : "ここを残す") { keep(folder, in: set) }
                            .buttonStyle(.pillSecondary).disabled(keptFolders[set.id] == folder)
                    }
                }
            }
        }
    }

    private func keep(_ folder: String, in set: DuplicateFolderSet) {
        selected.subtract(set.groups.flatMap(\.files).map(\.path))
        selected.formUnion(DuplicateFinder.keeping(folder, in: set))
        keptFolders[set.id] = folder
    }

    /// Only groups nothing has been chosen in, so earlier choices stand.
    private func selectRest(_ groups: [DuplicateGroup]) {
        selected.formUnion(DuplicateFinder.allButNewest(groups.filter { group in !group.files.contains { selected.contains($0.path) } }))
    }

    private func card(_ group: DuplicateGroup) -> some View {
        GlowCard(glow: .blue, style: .rim, padding: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(group.bytes.bytesText) × \(group.files.count)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                ForEach(group.files) { file in
                    HStack {
                        Toggle(isOn: Binding { selected.contains(file.path) } set: { on in
                            if on { selected.insert(file.path) } else { selected.remove(file.path) }
                        }) {
                            Text((file.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!selected.contains(file.path) && !DuplicateFinder.canSelect(file.path, in: group, selected: selected))
                        Spacer()
                        Button("Finder で表示") { NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "") }
                            .buttonStyle(.link).font(.system(size: 12))
                    }
                }
            }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saved = (folders + [(url.path as NSString).abbreviatingWithTildeInPath]).joined(separator: "\n")
    }

    private func start() {
        let roots = folders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } + chosenDrives
        selected = []
        keptFolders = [:]
        failed = 0
        limit = 30
        scanTask = Task {
            let task = Task.detached(priority: .utility) { DuplicateFinder.scan(roots) }
            let found = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            if !Task.isCancelled {
                groups = found
                selected = DuplicateFinder.downloadsRule(found, home: NSHomeDirectory())
            }
            scanTask = nil
        }
    }

    private func stop() { scanTask?.cancel() }

    private func ask() {
        let list = chosen
        confirm = .init(title: "\(list.reduce(Int64(0)) { $0 + $1.bytes }.bytesText) をゴミ箱に入れますか？",
                        message: "\(list.count) 項目をゴミ箱に入れます。各組の残りのファイルはそのままです。", button: "ゴミ箱に入れる") {
            let stuck = Trash.move(list.map(\.path))
            failed = stuck.count
            let gone = Set(list.map(\.path)).subtracting(stuck)
            selected = []
            groups = groups?.compactMap { group in
                let left = group.files.filter { !gone.contains($0.path) }
                return left.count > 1 ? DuplicateGroup(files: left) : nil
            }
        }
    }
}
