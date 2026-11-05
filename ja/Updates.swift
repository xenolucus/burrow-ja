import Sparkle
import SwiftUI

/// The running app's Sparkle updater. Nil in a development build, which names no feed.
enum AppUpdates {
    static var controller: SPUStandardUpdaterController?

    static func check() { controller?.checkForUpdates(nil) }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }
}

struct UpdatesCard: View {
    @State private var automatic = AppUpdates.controller?.updater.automaticallyChecksForUpdates ?? false

    var body: some View {
        GlowCard(glow: .sage, style: .rim, padding: 22) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("アップデート").cardTitle()
                    Text("現在のバージョン: \(AppUpdates.version)。更新前に変更内容を表示します。").caption()
                }
                Spacer()
                Toggle("自動で確認", isOn: $automatic)
                    .font(.system(size: 13)).toggleStyle(.switch).controlSize(.small)
                    .onChange(of: automatic) { _, on in AppUpdates.controller?.updater.automaticallyChecksForUpdates = on }
                Button("今すぐ確認") { AppUpdates.check() }
                    .buttonStyle(.pillSecondary)
                    .disabled(AppUpdates.controller == nil)
            }
        }
    }
}
