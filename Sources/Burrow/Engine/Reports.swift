import Foundation

// MARK: - Dry-run text reports

struct ReportItem: Identifiable, Hashable {
    enum Kind { case action, info, skipped, ok }
    /// Position in Mole's output, so a re-parse of a growing output keeps the same identity.
    let id: String
    let kind: Kind
    let name: String
    let detail: String
    let bytes: Int64?
}

struct ReportSection: Identifiable, Hashable {
    let id: String
    let title: String
    var items: [ReportItem]
    var bytes: Int64 { items.filter { $0.kind == .action }.compactMap(\.bytes).reduce(0, +) }
}

/// Mole's sectioned dry-run output (`mo clean -n`, `mo optimize -n`).
struct SectionReport {
    var notes: [String] = []
    var sections: [ReportSection] = []
    var summary: [String] = []

    /// Sum of the rows. Rows overlap (a cache folder and a cache inside it), so this is only a
    /// running figure while Mole scans; `total` is what a clean frees.
    var bytes: Int64 { sections.map(\.bytes).reduce(0, +) }
    var actionCount: Int { sections.flatMap(\.items).filter { $0.kind == .action }.count }

    /// Mole's own "Potential space" (de-duplicated), "+" when some sizes were unknown.
    var potential: Int64?
    var potentialIsLowerBound = false
    var itemCount: Int?
    var categoryCount: Int?

    /// What a clean frees: Mole's de-duplicated figure, else the row sum.
    var total: Int64 { potential ?? bytes }

    /// "622 items in 6 categories", from Mole's summary.
    var tally: String? {
        guard let items = itemCount else { return nil }
        let first = "\(items.formatted()) item\(items == 1 ? "" : "s")"
        guard let cats = categoryCount else { return first }
        return first + " in \(cats.formatted()) categor\(cats == 1 ? "y" : "ies")"
    }

    static func parse(_ output: String) -> SectionReport {
        var report = SectionReport()
        var inSummary = false
        for line in TerminalText.lines(output) {
            if line.hasPrefix("====") { inSummary.toggle(); continue }
            if inSummary {
                report.summary.append(line)
                // "Potential space: 11.27GB+ | Items: 622 | Categories: 6"
                if line.hasPrefix("Potential space:") {
                    for part in line.components(separatedBy: " | ") {
                        let value = part.components(separatedBy: ": ").last ?? ""
                        if part.hasPrefix("Potential space") {
                            report.potential = ByteSize.first(in: value)
                            report.potentialIsLowerBound = value.hasSuffix("+")
                        } else if part.hasPrefix("Items") {
                            report.itemCount = Int(value)
                        } else if part.hasPrefix("Categories") {
                            report.categoryCount = Int(value)
                        }
                    }
                }
                continue
            }
            if line.hasPrefix("➤") {
                let title = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                report.sections.append(.init(id: "\(report.sections.count)-\(title)", title: title, items: []))
                continue
            }
            guard let icon = line.first else { continue }
            let kind: ReportItem.Kind
            switch icon {
            case "→": kind = .action
            case "⊙": kind = .info
            case "◎": kind = .skipped
            case "✓": kind = .ok
            default: continue
            }
            let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            if report.sections.isEmpty {
                // The dry-run banner and the whitelist count are Mole talking to the terminal.
                if !body.hasPrefix("DRY RUN"), kind != .ok || !body.hasPrefix("Whitelist") { report.notes.append(body) }
                continue
            }
            let parts = body.components(separatedBy: " · ")
            let name: String, detail: String
            if parts.count > 1 {
                name = parts[0]
                detail = parts.dropFirst().joined(separator: " · ")
            } else if let comma = body.range(of: ", ") {
                name = String(body[..<comma.lowerBound])
                detail = String(body[comma.upperBound...])
            } else {
                name = body
                detail = ""
            }
            let bytes = detail.contains("protected") && detail.hasPrefix("0") ? nil : ByteSize.first(in: detail)
            let last = report.sections.count - 1
            report.sections[last].items.append(
                .init(id: "\(last).\(report.sections[last].items.count)", kind: kind, name: name,
                      detail: detail.replacingOccurrences(of: " dry", with: ""), bytes: bytes))
        }
        report.sections.removeAll { $0.items.isEmpty }
        return report
    }
}

/// `mo purge --dry-run`: one build artifact per line.
struct PurgeReport {
    struct Artifact: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let bytes: Int64
        var expandedPath: String { (path as NSString).expandingTildeInPath }
        var kind: String { (path as NSString).lastPathComponent }
        /// The project folder the artifact belongs to.
        var project: String {
            var url = URL(fileURLWithPath: expandedPath).deletingLastPathComponent()
            while ["packages", "apps", "plugin", "package", "android", "app"].contains(url.lastPathComponent) {
                url.deleteLastPathComponent()
            }
            return url.path
        }
    }

    var artifacts: [Artifact] = []
    var summary = ""
    /// Mole's warnings, for example scan roots it had to skip.
    var notes: [String] = []
    /// Scan roots Mole could not finish ("~", "~/PROJECTS/Big"), listed under its warning.
    var skippedRoots: [String] = []
    /// Build folders Mole could not check (for example in a git worktree whose repository is gone); it keeps them.
    var uninspected: [String] = []
    /// Mole reached its closing summary, so the list is whole even if it exited 1.
    var complete = false
    var bytes: Int64 { artifacts.map(\.bytes).reduce(0, +) }

    private static let skippedRoot = try! NSRegularExpression(pattern: "^(.+) \\(status [0-9]+\\)$")

    /// "◎ Could not inspect ~/a/dist; kept" → "~/a/dist".
    private static func uninspectedPath(_ line: String) -> String? {
        let path = line.dropFirst("◎ Could not inspect ".count).dropLast("; kept".count)
        return path.isEmpty ? nil : String(path)
    }

    static func parse(_ output: String) -> PurgeReport {
        var report = PurgeReport()
        var inSkipped = false
        for line in TerminalText.lines(output) {
            if inSkipped {
                let ns = NSRange(line.startIndex..., in: line)
                if let m = skippedRoot.firstMatch(in: line, range: ns), let r = Range(m.range(at: 1), in: line) {
                    report.skippedRoots.append(String(line[r]))
                    continue
                }
                if line.hasPrefix("and "), line.hasSuffix(" more") { continue }
                inSkipped = false
            }
            if line.hasPrefix("◎ Could not inspect "), line.hasSuffix("; kept") {
                uninspectedPath(line).map { report.uninspected.append($0) }
            } else if line.hasPrefix("Dry run incomplete") || line.hasPrefix("Dry run complete") {
                report.complete = true
            } else if line.hasPrefix("◎ Skipped") {
                // The heading ends with a colon; the roots follow on their own lines.
                var note = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if note.hasSuffix(":") { note.removeLast() }
                report.notes.append(note)
                inSkipped = true
            } else if let r = line.range(of: "[DRY RUN] ") {
                let rest = line[r.upperBound...]
                guard let comma = rest.range(of: ", ", options: .backwards) else { continue }
                report.artifacts.append(.init(path: String(rest[..<comma.lowerBound]),
                                              bytes: ByteSize.first(in: String(rest[comma.upperBound...])) ?? 0))
            } else if line.hasPrefix("Would free") {
                report.summary = line
            }
        }
        report.artifacts.sort { $0.bytes > $1.bytes }
        if !report.skippedRoots.isEmpty, let i = report.notes.firstIndex(where: { $0.hasPrefix("Skipped") }) {
            report.notes[i] += ": " + report.skippedRoots.joined(separator: ", ")
        }
        if !report.uninspected.isEmpty {
            let n = report.uninspected.count
            report.notes.append("Mole could not check \(n == 1 ? "this build folder" : "\(n) build folders"), so it keeps "
                                + "\(n == 1 ? "it" : "them"): " + report.uninspected.prefix(3).joined(separator: ", ")
                                + (n > 3 ? " and \(n - 3) more" : ""))
        }
        return report
    }
}

/// `mo slim --dry-run`: universal apps and their Intel code size.
struct SlimReport {
    struct App: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let bytes: Int64
    }

    var apps: [App] = []
    var summary = ""
    var bytes: Int64 { apps.map(\.bytes).reduce(0, +) }

    private static let row = try! NSRegularExpression(pattern: "^(.+?)\\s{2,}([0-9.]+\\s?(?:TB|GB|MB|KB|B))$")

    static func parse(_ output: String) -> SlimReport {
        var report = SlimReport()
        for line in TerminalText.lines(output) {
            if line.contains("of Intel code") { report.summary = line; continue }
            let ns = NSRange(line.startIndex..., in: line)
            guard let m = row.firstMatch(in: line, range: ns),
                  let n = Range(m.range(at: 1), in: line), let s = Range(m.range(at: 2), in: line) else { continue }
            report.apps.append(.init(name: String(line[n]), bytes: ByteSize.first(in: String(line[s])) ?? 0))
        }
        return report
    }
}

// MARK: - JSON reports

struct SystemStatus: Decodable {
    struct Hardware: Decodable { let model: String?; let cpu_model: String?; let total_ram: String?; let disk_size: String?; let os_version: String? }
    struct CPU: Decodable { let usage: Double; let per_core: [Double]?; let load1: Double?; let core_count: Int?; let p_core_count: Int?; let e_core_count: Int? }
    struct Memory: Decodable { let used: Int64; let total: Int64; let available: Int64?; let used_percent: Double; let swap_used: Int64?; let cached: Int64? }
    struct Disk: Decodable { let mount: String; let used: Int64; let total: Int64; let used_percent: Double?; let purgeable: Int64?; let external: Bool? }
    struct DiskIO: Decodable { let read_rate: Double?; let write_rate: Double? }
    struct Network: Decodable { let name: String; let rx_rate_mbs: Double?; let tx_rate_mbs: Double?; let ip: String? }
    struct Battery: Decodable { let percent: Double?; let status: String?; let time_left: String?; let health: String?; let cycle_count: Int?; let capacity: Double? }
    struct Thermal: Decodable { let cpu_temp: Double?; let battery_temp: Double?; let system_power: Double?; let adapter_power: Double? }
    struct Proc: Decodable, Identifiable { let pid: Int; let name: String; let cpu: Double; let memory: Double?; let memory_bytes: Int64?; var id: Int { pid } }

    let host: String?
    let uptime: String?
    let procs: Int?
    let hardware: Hardware?
    let health_score: Int?
    let health_score_msg: String?
    let cpu: CPU?
    let memory: Memory?
    let disks: [Disk]?
    let disk_io: DiskIO?
    let network: [Network]?
    let batteries: [Battery]?
    let thermal: Thermal?
    let trash_size: Int64?
    let top_processes: [Proc]?

    var rootDisk: Disk? { disks?.first { $0.mount == "/" } ?? disks?.first }
}

struct AnalyzeResult: Decodable {
    struct Entry: Decodable, Identifiable, Hashable {
        let name: String
        let path: String
        let size: Int64
        let is_dir: Bool?
        let last_access: String?
        /// Whole-Mac overview only: a summary such as "Old Downloads (90d+)", whose `path` is the
        /// folder it was found in and whose `size` is only the part it describes.
        let insight: Bool?
        let cleanable: Bool?
        var id: String { path + name }
        var isDirectory: Bool { is_dir ?? false }
        var isInsight: Bool { insight ?? false }
    }

    let path: String?
    /// True for the whole-Mac tour: its entries overlap (Home contains User Library) and do not add up.
    let overview: Bool?
    let scan_status: String?
    let entries: [Entry]?
    let large_files: [Entry]?
}

struct HistoryResult: Decodable {
    struct Session: Decodable, Identifiable, Hashable {
        struct Actions: Decodable, Hashable { let removed: Int?; let trashed: Int?; let skipped: Int?; let failed: Int?; let rebuilt: Int? }
        let command: String
        let started_at: String
        let ended_at: String?
        let items: Int?
        let size: String?
        let failed_tasks: Int?
        let actions: Actions?
        var id: String { command + started_at }
    }
    struct Deletion: Decodable, Identifiable, Hashable {
        let time: String?
        let path: String?
        let size: String?
        let action: String?
        let command: String?
        var id: String { (time ?? "") + (path ?? "") }
    }

    let sessions: [Session]?
    let deletions: [Deletion]?
}

struct InstalledApp: Decodable, Identifiable, Hashable {
    let name: String
    let bundle_id: String?
    let source: String?
    let uninstall_name: String
    let path: String
    /// Mole's own measurement ("1.2GB"), cached by Mole between runs.
    let size: String?
    var id: String { path }
    var bytes: Int64? { size.flatMap { ByteSize.first(in: $0) } }
}

// MARK: - A real run, live

/// What a real Mole run has done so far, read from its terminal output: what it is doing now,
/// the steps it finished, and how much it freed. The run sheet draws this instead of the log.
struct RunProgress: Equatable {
    struct Step: Identifiable, Equatable {
        enum Kind { case done, note, failed }
        let id: Int
        let kind: Kind
        /// The ➤ heading it ran under ("User essentials").
        let section: String?
        let name: String
        let detail: String
        let bytes: Int64?
    }

    var steps: [Step] = []
    /// What Mole listed before it started ("◎ Google Chrome, 576MB" above its confirmation).
    var planned: [Step] = []
    /// The files Mole shows for its confirmation ("Files to be removed:"), grouped by app in `section`.
    var review: [Step] = []
    /// A dry run: nothing is removed, the totals are what a real run would free.
    var dryRun = false
    /// The total in Mole's question ("Remove 2 apps, 90.5MB  Enter confirm").
    var promptBytes: Int64?
    /// The spinner's text: "Slimming Google Chrome".
    var now: String?
    /// "[2/5]" in Mole's output: which item of how many, and whether that item is finished.
    var position: (at: Int, of: Int)?
    var positionDone = false
    /// Mole's own total from its closing summary ("freed 576.3MB", "Tracked cleanup: 1.2GB").
    var summaryBytes: Int64?

    var freed: Int64 {
        summaryBytes ?? steps.filter { $0.kind == .done }.compactMap(\.bytes).reduce(0) { $0.addingReportingOverflow($1).overflow ? .max : $0 + $1 }
    }

    static func == (a: Self, b: Self) -> Bool {
        a.steps == b.steps && a.planned == b.planned && a.review == b.review && a.dryRun == b.dryRun && a.now == b.now
            && a.position?.at == b.position?.at && a.position?.of == b.position?.of && a.positionDone == b.positionDone
            && a.summaryBytes == b.summaryBytes && a.promptBytes == b.promptBytes
    }

    private static let counter = try! NSRegularExpression(pattern: "^\\[([0-9]+)/([0-9]+)\\]\\s*")
    /// Mole's closing totals: slim and uninstall ("Slimmed 2 apps, freed 1.2GB"), clean, purge.
    private static let summary = try! NSRegularExpression(
        pattern: "^(?:(?:Slimmed|Removed|Uninstalled|Would remove) [^:]*?, (?:freed|would free)|Tracked cleanup:|Estimated space freed:|Space freed:)\\s*([0-9.]+\\s?(?:TB|GB|MB|KB|B))",
        options: .caseInsensitive)
    /// The closing line of a run over apps, with or without a size: every listed app it did not report failed is done.
    private static let closing = try! NSRegularExpression(pattern: "^(?:Slimmed|Removed|Uninstalled|Would remove) ([0-9]+) apps?\\b")
    /// Uninstall's match list: "1. Slack  212MB  |  Last: 2d ago" (the size is "--" while unknown).
    private static let matched = try! NSRegularExpression(pattern: "^[0-9]+\\. (.+?)\\s{2,}(\\S+)\\s{2,}\\|\\s+Last: (.+)$")

    static func parse(lines: [String], live: String) -> RunProgress {
        var p = RunProgress()
        var section: String?
        var reviewing = false
        var group: String?
        var named: Set<String> = []
        var closedCount: Int?
        for line in lines {
            guard let icon = line.first else { continue }
            let ns = NSRange(line.startIndex..., in: line)
            if let m = summary.firstMatch(in: line, range: ns), let r = Range(m.range(at: 1), in: line) {
                p.summaryBytes = ByteSize.first(in: String(line[r]))
            }
            if let m = closing.firstMatch(in: line, range: ns) {
                // "Removed 1 app, freed 2.7GB: CounterFlame": the apps it names are done.
                closedCount = Range(m.range(at: 1), in: line).flatMap { Int(line[$0]) }
                if let colon = line.range(of: ": ") {
                    named.formUnion(line[colon.upperBound...].components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) })
                }
                reviewing = false
            }
            if line.contains("DRY RUN") || line.hasPrefix("Would remove") { p.dryRun = true }
            // Mole lists what it will do (uninstall prints ✓ rows) before it asks; that was a preview.
            if line.range(of: "enter confirm", options: .caseInsensitive) != nil
                || line.range(of: "esc cancel", options: .caseInsensitive) != nil {
                p.promptBytes = ByteSize.first(in: line)
                p.steps.removeAll()
                p.position = nil
                // A dry run's list is its result; a real run has started on it.
                if !p.dryRun { p.review.removeAll() }
                reviewing = false
                continue
            }
            // Mole redraws the list when its personal-data choice changes: the new list replaces the old.
            if line == "Files to be removed:" { reviewing = true; p.review.removeAll(); continue }
            if line == "Personal data to remove:" { reviewing = true; group = "Personal data"; continue }
            if line == "Personal data kept:" { reviewing = false; continue }
            if p.steps.isEmpty, let m = matched.firstMatch(in: line, range: ns),
               let n = Range(m.range(at: 1), in: line), let s = Range(m.range(at: 2), in: line), let l = Range(m.range(at: 3), in: line) {
                p.plan(String(line[n]), bytes: ByteSize.first(in: String(line[s])), detail: "Last used \(line[l])")
                continue
            }
            var body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            if reviewing {
                // "◎ Slack , 212MB" opens an app's group; "✓ ~/Library/Caches/com.slack , 1MB" is one of its files,
                // "◎ System: /Library/…" one that needs the admin password.
                let (text, size) = nameAndSize(body)
                if icon == "◎", let header = body.range(of: " , ", options: .backwards), !body.contains(":") {
                    // "◎ Firefox [Brew] , 210MB", "◎ Steam , N/A (Steam-managed)": the app is named as in the match list.
                    var app = String(body[..<header.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if app.hasSuffix(" [Brew]") { app.removeLast(7) }
                    p.plan(app, bytes: ByteSize.first(in: String(body[header.upperBound...])), detail: nil)
                    group = app
                } else if icon == "◎", !text.hasPrefix("System:"), !text.hasPrefix("Review only:") {
                    // A note under the app ("Steam launcher only; game files … are not included").
                    p.review.append(.init(id: p.review.count, kind: .note, section: group, name: text, detail: "", bytes: nil))
                } else if icon == "✓" || icon == "◎" {
                    let colon = text.range(of: ": ")
                    let path = (colon.map { String(text[$0.upperBound...]) } ?? text) as NSString
                    // Mole's labels, in words a user can act on.
                    let label = colon.map { String(text[..<$0.lowerBound]) }
                        .map { ["System": "Needs your password", "Review only": "Kept, check it yourself"][$0] ?? $0 }
                    p.review.append(.init(id: p.review.count, kind: icon == "✓" ? .done : .note, section: group, name: path.lastPathComponent,
                                          detail: [label, path.deletingLastPathComponent].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                          bytes: ByteSize.first(in: size)))
                }
                continue
            }
            let kind: Step.Kind
            switch icon {
            case "➤":
                // Headings, not the "➤ Slim 1 app, 576MB  Enter confirm" prompt.
                if !body.hasSuffix(":"), body.range(of: "enter confirm", options: .caseInsensitive) == nil { section = body }
                continue
            case "✓": kind = .done
            case "☻", "✗": kind = .failed
            // ◎ with a size, before any work, lists what Mole is about to do; otherwise it is a warning.
            case "◎":
                // A heading such as "Matched 2 app(s):", not a step.
                if body.hasPrefix("Matched ") || body.hasPrefix("Selected ") { continue }
                // The list above a confirmation: no section, no "[n/m]", nothing done yet.
                // Not a diagnosis such as "Memory pressure: swap 15GB of 16GB used, 36% free".
                let (name, size) = nameAndSize(body)
                if let bytes = ByteSize.first(in: size), section == nil, p.steps.isEmpty, !body.hasPrefix("["), !name.contains(":") {
                    p.plan(name, bytes: bytes, detail: nil)
                    continue
                }
                kind = .note
            default: continue
            }
            if let (at, of) = strip(&body) { (p.position, p.positionDone) = ((at, of), true) }
            let parts = body.components(separatedBy: " · ")
            let name: String, detail: String
            if parts.count > 1 {
                (name, detail) = (parts[0], parts.dropFirst().joined(separator: " · "))
            } else if kind == .failed, let failed = body.range(of: " failed: ") {
                // "☻ CounterFlame failed: still running"
                (name, detail) = (String(body[..<failed.lowerBound]), String(body[failed.upperBound...]))
            } else if let comma = body.range(of: ", ") {
                (name, detail) = (String(body[..<comma.lowerBound]), String(body[comma.upperBound...]))
            } else {
                (name, detail) = (body, "")
            }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            // "✓ [1/2] Qalta" carries no size: the app's row keeps the one Mole listed for it.
            let listed = kind == .done ? p.planned.first { $0.name == trimmed } : nil
            p.steps.append(.init(id: p.steps.count, kind: kind, section: section, name: trimmed,
                                 detail: detail.isEmpty ? listed?.detail ?? "" : detail, bytes: ByteSize.first(in: detail) ?? listed?.bytes))
        }
        // The question still open on screen carries Mole's own total.
        if live.range(of: "enter confirm", options: .caseInsensitive) != nil { p.promptBytes = ByteSize.first(in: live) ?? p.promptBytes }
        // The spinner line: a braille frame, then the message.
        if let first = live.unicodeScalars.first, (0x2800...0x28FF).contains(first.value) {
            var text = String(live.unicodeScalars.dropFirst().map(Character.init)).trimmingCharacters(in: .whitespaces)
            if let (at, of) = strip(&text) { (p.position, p.positionDone) = ((at, of), false) }
            while text.hasSuffix(".") || text.hasSuffix("…") { text.removeLast() }
            // "Removing Qalta (74.8MB)": the row for the app already shows its size.
            if text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards),
               ByteSize.first(in: String(text[open.upperBound...])) != nil { text.removeSubrange(open.lowerBound...) }
            if !text.isEmpty { p.now = text }
        }
        // A single app gets no "✓ [1/1]" line; Mole's closing line is the only word that it is done.
        // Mole names apps by bundle there ("WeChat" for "微信"): when it removed as many as it listed, all of them are done.
        let all = closedCount == p.planned.count
        for item in p.planned where !p.dryRun && (all || named.contains(item.name)) && !p.steps.contains(where: { $0.name == item.name }) {
            p.steps.append(.init(id: p.steps.count, kind: .done, section: nil, name: item.name, detail: item.detail, bytes: item.bytes))
        }
        return p
    }

    /// Adds an item to the list Mole is about to work on, or fills in what a later line knows about it.
    private mutating func plan(_ name: String, bytes: Int64?, detail: String?) {
        if let i = planned.firstIndex(where: { $0.name == name }) {
            let old = planned[i]
            planned[i] = .init(id: old.id, kind: .note, section: nil, name: name, detail: detail ?? old.detail, bytes: bytes ?? old.bytes)
        } else {
            planned.append(.init(id: planned.count, kind: .note, section: nil, name: name, detail: detail ?? "", bytes: bytes))
        }
    }

    /// "Slack , 212MB" → ("Slack", "212MB"); the size follows the last comma.
    private static func nameAndSize(_ s: String) -> (String, String) {
        guard let comma = s.range(of: ",", options: .backwards), ByteSize.first(in: String(s[comma.upperBound...])) != nil else { return (s, "") }
        return (s[..<comma.lowerBound].trimmingCharacters(in: .whitespaces), String(s[comma.upperBound...]))
    }

    /// Takes a leading "[2/5] " off and returns its numbers.
    private static func strip(_ s: inout String) -> (Int, Int)? {
        let ns = NSRange(s.startIndex..., in: s)
        guard let m = counter.firstMatch(in: s, range: ns), let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s),
              let at = Int(s[a]), let of = Int(s[b]), let all = Range(m.range, in: s) else { return nil }
        s.removeSubrange(all)
        return (at, of)
    }
}
