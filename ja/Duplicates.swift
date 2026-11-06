import AppKit
import CryptoKit
import SwiftUI

struct DuplicateFile: Identifiable, Hashable, Sendable {
    let path: String
    let bytes: Int64
    let modified: Date
    var id: String { path }
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let files: [DuplicateFile]
    var id: String { files[0].path }
    var bytes: Int64 { files[0].bytes }
    var extra: Int64 { bytes * Int64(files.count - 1) }
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
            guard let chunk = try? file.read(upToCount: 1 << 20) else { return nil }
            if chunk.isEmpty { return hasher.finalize() }
            hasher.update(data: chunk)
        }
        return nil
    }

    static func scan(_ roots: [URL]) -> [DuplicateGroup] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
                                      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var bySize: [Int64: [DuplicateFile]] = [:]
        var seen = Set<NSObject>()  // a hard link is one file, however many names it has
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if Task.isCancelled { return [] }
                if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let size = values.fileSize, Int64(size) >= minBytes,
                      // Hashing a file that lives in iCloud would download it.
                      values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current,
                      let identity = values.fileResourceIdentifier as? NSObject, seen.insert(identity).inserted else { continue }
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

    private var folders: [String] {
        let list = saved.split(separator: "\n").map(String.init)
        return list.isEmpty ? ["~/Downloads", "~/Desktop", "~/Documents"] : list
    }
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
    }

    @ViewBuilder private func results(_ groups: [DuplicateGroup]) -> some View {
        if groups.isEmpty {
            EmptyState(symbol: "doc.on.doc", text: "重複は見つかりませんでした。", detail: "")
        } else {
            HStack {
                Text("\(groups.count) 組、\(groups.reduce(Int64(0)) { $0 + $1.extra }.bytesText) 空けられます").font(.system(size: 13, weight: .medium))
                Spacer()
                Button("新しいものを残して選択") { selected = DuplicateFinder.allButNewest(groups) }.buttonStyle(.pillSecondary)
                Button("ゴミ箱に入れる") { ask() }.buttonStyle(.pill).disabled(selected.isEmpty)
            }
            if failed > 0 {
                Text("\(failed) 項目をゴミ箱に入れられませんでした。").font(.system(size: 12)).foregroundStyle(Theme.danger)
            }
            ForEach(groups.prefix(limit)) { card($0) }
            if groups.count > limit {
                Button("さらに表示") { limit += 30 }.buttonStyle(.link).font(.system(size: 12))
            }
        }
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
        let roots = folders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        selected = []
        failed = 0
        limit = 30
        scanTask = Task {
            let task = Task.detached(priority: .utility) { DuplicateFinder.scan(roots) }
            let found = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            if !Task.isCancelled { groups = found }
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
