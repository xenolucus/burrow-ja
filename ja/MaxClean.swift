import SwiftUI

/// Lifts Mole's protection from caches that rebuild themselves, for people who want the most space back.
/// The switch reads the whitelist itself, so it can never disagree with the list on the same page.
enum MaxClean {
    /// Rebuilt or downloaded again on next use.
    static let replaceable = [
        "~/.gradle/daemon/*", "~/.gradle/caches/*", "~/Library/Caches/tealdeer/tldr-pages", "~/Library/Caches/ms-playwright*",
        "~/Library/Caches/com.nssurge.surge-mac/*", "~/Library/Caches/JetBrains*", "~/Library/Caches/com.jetbrains.toolbox*",
        "~/Library/Caches/com.apple.finder",
    ]
    /// User data and settings, and models chosen by hand. These stay protected either way.
    private static let kept = [
        "~/.ollama/models/*", "~/Library/Application Support/com.nssurge.surge-mac/*", "~/Library/Application Support/JetBrains*",
        "~/Library/Mobile Documents*", "FINDER_METADATA",
    ]

    private static func path(_ entry: String) -> String {
        let home = NSHomeDirectory()
        return (entry.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
                as NSString).expandingTildeInPath
    }

    private static func isReplaceable(_ entry: String) -> Bool { replaceable.map(path).contains(path(entry)) }

    static func isOn(_ entries: [String]) -> Bool { !entries.isEmpty && !entries.contains(where: isReplaceable) }

    static func entries(_ current: [String], on: Bool) -> [String] {
        // Without a whitelist Mole uses its defaults, and a saved file replaces them, so start from those.
        let base = current.isEmpty ? kept : current
        if on { return base.filter { !isReplaceable($0) } }
        return base + replaceable.filter { entry in !base.contains { path($0) == path(entry) } }
    }
}

struct MaxCleanCard: View {
    @Binding var entries: [String]

    var body: some View {
        GlowCard(glow: .ember, style: .rim, padding: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("キャッシュを最大限に消す", isOn: Binding { MaxClean.isOn(entries) } set: { on in
                    entries = MaxClean.entries(entries, on: on)
                    ConfigList.whitelist.write(entries)
                })
                .font(.system(size: 13)).toggleStyle(.switch).controlSize(.small)
                Text("作り直せるキャッシュの保護を外します。次回の起動が遅くなったり、再ダウンロードが発生したりします。iCloud、アプリの設定、Ollama のモデルは保護したままです。オフに戻すと保護も戻ります。").caption()
            }
        }
    }
}
