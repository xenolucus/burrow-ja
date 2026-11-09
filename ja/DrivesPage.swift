import AppKit
import SwiftUI

struct DriveInfo: Equatable {
    let model: String
    let connection: String
    let fileSystem: String
    let health: String
    let total: Int64
    let free: Int64

    /// From `diskutil info -plist`. USB drives usually keep their SMART data from macOS.
    static func parse(_ data: Data) -> DriveInfo? {
        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let health = switch info["SMARTStatus"] as? String {
        case "Verified": "正常"
        case "Failing": "異常（早めにバックアップを）"
        default: "このドライブでは取得できません"
        }
        return DriveInfo(model: info["MediaName"] as? String ?? "不明",
                         connection: info["BusProtocol"] as? String ?? "不明",
                         fileSystem: info["FilesystemUserVisibleName"] as? String ?? "不明",
                         health: health,
                         total: (info["TotalSize"] as? NSNumber)?.int64Value ?? 0,
                         free: ((info["APFSContainerFree"] ?? info["FreeSpace"]) as? NSNumber)?.int64Value ?? 0)
    }

    static func read(_ drive: URL) -> DriveInfo? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", drive.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? parse(data) : nil
    }
}

struct OldVideo: Identifiable, Hashable {
    let path: String
    let bytes: Int64
    let lastUsed: Date
    var id: String { path }
}

enum OldVideoScanner {
    static let extensions: Set<String> = ["mp4", "mov", "m4v", "mxf", "avi", "mkv", "r3d", "braw"]
    static let minBytes: Int64 = 500_000_000
    static let idle: TimeInterval = 365 * 86400

    static func isOld(path: String, bytes: Int64, lastUsed: Date, now: Date) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased()) && bytes >= minBytes
            && now.timeIntervalSince(lastUsed) >= idle
    }

    /// Read-only: lists files and never changes them.
    /// shortcut: stops after `limit` seconds, a huge drive shows only what was found by then.
    static func scan(_ root: URL, limit: TimeInterval = 30, now: Date = Date()) -> [OldVideo] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .contentAccessDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                          errorHandler: { _, _ in true }) else { return [] }
        let started = Date()
        var found: [OldVideo] = []
        for case let url as URL in walker {
            if Date().timeIntervalSince(started) > limit { break }
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let lastUsed = max(values.contentModificationDate ?? .distantPast, values.contentAccessDate ?? .distantPast)
            let bytes = Int64(values.fileSize ?? 0)
            if isOld(path: url.path, bytes: bytes, lastUsed: lastUsed, now: now) {
                found.append(.init(path: url.path, bytes: bytes, lastUsed: lastUsed))
            }
        }
        return found.sorted { $0.bytes > $1.bytes }
    }
}

struct DrivesPage: View {
    @ViewState private var drives: [URL] = []
    @ViewState private var scanning: URL?
    @ViewState private var videos: [String: [OldVideo]] = [:]

    private let mounts = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
    private let unmounts = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if drives.isEmpty {
                EmptyState(symbol: "externaldrive", text: "外付けドライブは接続されていません。",
                           detail: "接続すると、状態と古い動画を確認できます。")
            }
            ForEach(drives, id: \.self) { drive in card(drive) }
        }
        .onAppear { drives = ExternalDrives.mounted() }
        .onReceive(mounts) { _ in drives = ExternalDrives.mounted() }
        .onReceive(unmounts) { _ in drives = ExternalDrives.mounted() }
    }

    private func card(_ drive: URL) -> some View {
        let info = DriveInfo.read(drive)
        return GlowCard(glow: .blue, style: .rim, padding: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(verbatim: drive.lastPathComponent).cardTitle()
                    Spacer()
                    Button("古い動画を探す") { find(drive) }.buttonStyle(.pillSecondary).disabled(scanning != nil)
                }
                if let info {
                    row("状態", info.health)
                    row("モデル", info.model)
                    row("接続", "\(info.connection) / \(info.fileSystem)")
                    row("空き容量", "\(info.free.bytesText) / \(info.total.bytesText)")
                }
                if scanning == drive { Text("確認しています（最大30秒）…").caption() }
                if let list = videos[drive.path] { videoList(list) }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
    }

    @ViewBuilder private func videoList(_ list: [OldVideo]) -> some View {
        Text(list.isEmpty ? "1年以上使っていない 500 MB 以上の動画はありません。"
                          : "1年以上使っていない動画 \(list.count) 件・\(list.map(\.bytes).reduce(0, +).bytesText)").caption()
        ForEach(list.prefix(50)) { video in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: (video.path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(video.lastUsed.formatted(date: .abbreviated, time: .omitted)).caption()
                }
                Spacer()
                Text(video.bytes.bytesText).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Button("Finder で表示") { NSWorkspace.shared.selectFile(video.path, inFileViewerRootedAtPath: "") }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        }
    }

    private func find(_ drive: URL) {
        scanning = drive
        Task {
            videos[drive.path] = await Task.detached(priority: .utility) { OldVideoScanner.scan(drive) }.value
            scanning = nil
        }
    }
}
