import AppKit
import SwiftUI

/// How to clear what Mole lists but leaves to the user. Commands are copied, never run.
struct ManualGuide {
    var text: String
    var command: String? = nil
    var app: String? = nil
    var folder: String? = nil

    /// Keyed by Mole's row name.
    static let all: [String: ManualGuide] = [
        "Docker Desktop data": .init(text: "Docker Desktop を起動して次のコマンドを実行します。停止中のコンテナと未使用のイメージが消えます。ボリュームは残ります。",
                                     command: "docker system prune -a", app: "com.docker.docker"),
        "LM Studio models": .init(text: "LM Studio の「My Models」で使わないモデルを削除します。再び使うにはダウンロードが必要です。",
                                  app: "ai.elementlabs.lmstudio", folder: "~/.lmstudio/models"),
        "NuGet packages": .init(text: "次のビルドで再ダウンロードされます。", command: "dotnet nuget locals global-packages --clear"),
        "Xcode DerivedData": .init(text: "次のビルドで作り直されます。Xcode を閉じてから実行します。", command: "rm -rf ~/Library/Developer/Xcode/DerivedData"),
        "Xcode archives": .init(text: "Xcode の Organizer で古いアーカイブを削除します。提出済みアプリの記号情報も消えるので、残すものを確認してください。",
                                app: "com.apple.dt.Xcode", folder: "~/Library/Developer/Xcode/Archives"),
        "Simulator data": .init(text: "今の Xcode で使えないシミュレータを削除します。", command: "xcrun simctl delete unavailable"),
        "iOS backups": .init(text: "Finder で iPhone を選び、「バックアップを管理」から古いものを削除します。元に戻せません。"),
        "Maven local repository": .init(text: "次のビルドで再ダウンロードされます。", command: "rm -rf ~/.m2/repository"),
        "Ivy local repository": .init(text: "次のビルドで再ダウンロードされます。", command: "rm -rf ~/.ivy2/cache"),
        "Gradle caches": .init(text: "次のビルドで再ダウンロードされます。", command: "rm -rf ~/.gradle/caches"),
        "pnpm store": .init(text: "どのプロジェクトからも使われていないパッケージを削除します。", command: "pnpm store prune"),
        "Conda packages": .init(text: "使われていないパッケージとキャッシュを削除します。", command: "conda clean --all"),
        "Anaconda packages": .init(text: "使われていないパッケージとキャッシュを削除します。", command: "conda clean --all"),
        "OrbStack data": .init(text: "OrbStack で使っていないコンテナやイメージを削除します。", app: "dev.kdrag0n.MacVirt"),
        "Lima data": .init(text: "一覧を確認し、不要な VM を `limactl delete 名前` で削除します。", command: "limactl list"),
        "Mail data": .init(text: "メールアプリで不要なメールボックスや添付ファイルを整理します。", app: "com.apple.mail"),
        "macOS updates cache": .init(text: "macOS のアップデートを適用すると解消します。"),
    ]
}

struct ManualGuideButton: View {
    let name: String
    @ViewState private var showing = false

    var body: some View {
        if let guide = ManualGuide.all[name] {
            Button("消し方") { showing = true }
                .buttonStyle(.link).font(.system(size: 12, weight: .medium))
                .popover(isPresented: $showing, arrowEdge: .bottom) { content(guide) }
        }
    }

    private func content(_ guide: ManualGuide) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(guide.text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            if let command = guide.command {
                Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            HStack(spacing: 12) {
                if let command = guide.command {
                    Button("コマンドをコピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
                if let app = guide.app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                    Button("アプリを開く") { NSWorkspace.shared.open(url) }
                }
                if let folder = guide.folder {
                    Button("Finder で表示") {
                        NSWorkspace.shared.selectFile((folder as NSString).expandingTildeInPath, inFileViewerRootedAtPath: "")
                    }
                }
            }
            .buttonStyle(.link).font(.system(size: 12))
        }
        .padding(14).frame(width: 340, alignment: .leading)
    }
}
