import AppKit
import SwiftUI

/// Experimental: `mo clean --external`. Mole removes only OS metadata (.DS_Store, ._* files and
/// temporary folders) and refuses internal volumes; the volume's Trash and user files are kept.
enum ExternalDrives {
    static let enabledKey = "experimentalExternalClean"

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

struct ExternalCleanCard: View {
    let model: AppModel
    @AppStorage(ExternalDrives.enabledKey) private var enabled = false
    @State private var drives: [URL] = []
    @State private var confirm: ConfirmAction?

    private let mounts = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
    private let unmounts = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)

    var body: some View {
        if enabled {
            GlowCard(glow: .ember, style: .rim, padding: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("外付けドライブ（試験的）").cardTitle()
                    Text("Mac が作った .DS_Store、._ で始まるファイル、一時フォルダだけを削除します。ゴミ箱と自分のファイルには触れません。").caption()
                    if drives.isEmpty {
                        Text("外付けドライブは接続されていません。").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(drives, id: \.self) { drive in
                        HStack {
                            Text(drive.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                            Button("プレビュー") { run(drive, preview: true) }.buttonStyle(.pillSecondary)
                            Button("クリーン") { ask(drive) }.buttonStyle(.pill)
                        }
                    }
                }
            }
            .onAppear { drives = ExternalDrives.mounted() }
            .onReceive(mounts) { _ in drives = ExternalDrives.mounted() }
            .onReceive(unmounts) { _ in drives = ExternalDrives.mounted() }
            .confirmation($confirm)
        }
    }

    private func run(_ drive: URL, preview: Bool) {
        model.run("\(drive.lastPathComponent) を\(preview ? "プレビュー" : "クリーン")しています",
                  ["clean", "--external", drive.path] + (preview ? ["--dry-run"] : []))
    }

    private func ask(_ drive: URL) {
        confirm = .init(title: "\(drive.lastPathComponent) をクリーンしますか？",
                        message: "試験的な機能です。先にプレビューで内容を確認してください。",
                        button: "クリーン") { run(drive, preview: false) }
    }
}

struct ExperimentalCard: View {
    @AppStorage(ExternalDrives.enabledKey) private var enabled = false

    var body: some View {
        GlowCard(glow: .ember, style: .rim, padding: 22) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("試験的な機能").cardTitle()
                    Text("外付け SSD や HDD をクリーンの対象にします。予告なく変更する場合があります。").caption()
                }
                Spacer()
                Toggle("外付けドライブのクリーン", isOn: $enabled)
                    .font(.system(size: 13)).toggleStyle(.switch).controlSize(.small)
            }
        }
    }
}
