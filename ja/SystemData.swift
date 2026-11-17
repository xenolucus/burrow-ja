import Foundation

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
