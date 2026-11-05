import SwiftUI

/// Japanese for text that only exists at run time: Mole's output and run titles.
/// Parsers keep reading Mole's English; translation happens only when a string is drawn.
enum JA {
    private static let hand: [String: String] = [
        "Clean": "クリーン", "Uninstall": "アンインストール", "Optimize": "最適化", "Slim": "スリム化",
        "Remove": "削除", "Delete": "削除", "Purge": "整理", "Confirm": "確定", "Continue": "続行",
        "Enter": "決定", "Skip": "スキップ", "Space": "スキップ", "Yes": "はい", "No": "いいえ", "Cancel": "キャンセル",
        "Installer": "インストーラ", "Touchid": "Touch ID", "Would apply": "適用予定",
        "Personal data": "個人データ", "System": "システム", "Review only": "確認のみ",
        "Trash": "ゴミ箱", "Grant Full Disk Access to Burrow": "Burrow にフルディスクアクセスを許可してください",
    ]

    private static let rules: [(NSRegularExpression, String)] = [
        (#"^Remove ([0-9]+) apps?, (.+)\?$"#, "$1 個のアプリを削除しますか？（$2）"),
        (#"^Uninstall ([0-9]+) apps?, (.+)\?$"#, "$1 個のアプリをアンインストールしますか？（$2）"),
        (#"^Slim ([0-9]+) apps?, (.+)\?$"#, "$1 個のアプリをスリム化しますか？（$2）"),
        (#"^Would free (.+)$"#, "$1 を解放予定"),
        (#"^Freed (.+)$"#, "$1 を解放"),
        (#"^([0-9,]+) items?$"#, "$1 項目"),
        (#"^(.+) caches?$"#, "$1 のキャッシュ"),
        (#"^(.+) logs$"#, "$1 のログ"),
    ].compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    static func t(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 >= 65 && $0 <= 122 }) else { return text }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = hand[key] ?? JAGenerated.table[key] { return found }
        let range = NSRange(key.startIndex..., in: key)
        for (regex, template) in rules where regex.firstMatch(in: key, range: range) != nil {
            return regex.stringByReplacingMatches(in: key, range: range, withTemplate: template)
        }
        return text
    }
}

extension Text {
    /// Every `Text(someString)` in the app passes through here; other modules are untouched.
    init(_ content: String) { self.init(verbatim: JA.t(content)) }
}
