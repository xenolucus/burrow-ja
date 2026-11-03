import SwiftUI

/// Installed apps as Mole sees them. Sizes come from Mole's own list (it caches them),
/// so nothing is measured twice and the grid is ready as soon as the list is.
@MainActor
final class AppCatalog: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var loading = false
    @Published var error: String?
    private(set) var checkedAt: Date?
    private static let cacheKey = "uninstall --list"

    init() {
        if let saved = ResultCache.load(Self.cacheKey), let list = try? Mole.decode([InstalledApp].self, from: saved.data) {
            apps = list
            checkedAt = saved.date
        }
    }

    private var loadTask: Task<Void, Never>?

    /// A second caller waits for the list already loading instead of starting another.
    func load() async {
        if let loadTask { return await loadTask.value }
        let task = Task { await fetch() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func fetch() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let data = try await Mole.capture(["uninstall", "--list"])
            apps = try Mole.decode([InstalledApp].self, from: data)
            checkedAt = Date()
            ResultCache.save(data, as: Self.cacheKey)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshIfStale() async {
        if ResultCache.isStale(checkedAt) { await load() }
    }
}

enum FolderSize {
    /// Allocated size of a file or folder, without following symlinks.
    nonisolated static func of(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true {
            return Int64(v.totalFileAllocatedSize ?? 0)
        }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

struct UninstallPage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var catalog: AppCatalog
    let leftovers: LeftoverStore
    @AppStorage("uninstall.showLeftovers") private var showLeftovers = false
    @ViewState private var query = ""
    @ViewState private var selected = Set<String>()
    @AppStorage("uninstall.sortBySize") private var sortBySize = true
    @AppStorage("uninstall.withData") private var withData = false
    @AppStorage("uninstall.permanent") private var permanent = false
    @ViewState private var confirm: ConfirmAction?
    @FocusState private var searchFocused: Bool

    private var visible: [InstalledApp] {
        let list = catalog.apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        return sortBySize ? list.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
                          : list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var chosen: [InstalledApp] { catalog.apps.filter { selected.contains($0.path) } }
    private var chosenBytes: Int64 { chosen.compactMap(\.bytes).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PillPicker(selection: $showLeftovers, options: [("Apps", false), ("Leftovers", true)])
            if showLeftovers {
                LeftoversView(store: leftovers).transition(.opacity)
            } else {
                installed.transition(.opacity)
            }
        }
    }

    private var installed: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                SearchField(text: $query, prompt: catalog.apps.isEmpty ? "Search apps" : "Search \(catalog.apps.count) apps",
                            focused: $searchFocused)
                PillPicker(selection: $sortBySize, options: [("Largest", true), ("A–Z", false)])
                if let at = catalog.checkedAt, !catalog.loading { CheckedAgo(date: at) }
                CircleIconButton(symbol: "arrow.clockwise", help: "Reload the app list") { Task { await catalog.load() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(catalog.loading)
                Button("Search") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }

            if catalog.apps.isEmpty {
                if let error = catalog.error {
                    EmptyState(symbol: "exclamationmark.triangle", text: "Mole could not list your apps", detail: error,
                               actionTitle: "Try again") { Task { await catalog.load() } }
                } else if catalog.loading {
                    skeleton
                } else {
                    EmptyState(symbol: "app.dashed", text: "No apps found.")
                }
            } else if visible.isEmpty {
                EmptyState(symbol: "magnifyingglass", text: "No app matches “\(query)”.", actionTitle: "Clear search") { query = "" }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                    ForEach(visible) { app in
                        AppTile(app: app, selected: selected.contains(app.path)) {
                            if selected.contains(app.path) { selected.remove(app.path) } else { selected.insert(app.path) }
                        }
                    }
                }
                .animation(Motion.spring, value: sortBySize)
                .animation(Motion.quick, value: query)
                Text("Sizes are the app bundles as Mole measured them. Leftovers are listed in the preview.").caption()
            }
        }
        .bottomBar(!selected.isEmpty) { actionBar }
        .confirmation($confirm)
        // Not `.task`: leaving the page must not cancel Mole half way through the list.
        .onAppear { if catalog.apps.isEmpty { Task { await catalog.load() } } }
    }

    /// Placeholder tiles while Mole lists the apps (it takes a few seconds the first time).
    private var skeleton: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
            ForEach(0..<12, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
                    .frame(height: 64)
                    .shimmer()
            }
        }
        .accessibilityLabel("Finding your apps")
    }

    private var actionBar: some View {
        SelectionBar(glow: .ember, title: "\(chosen.count) selected · \(chosenBytes.bytesText)",
                     subtitle: chosen.prefix(3).map(\.name).joined(separator: ", ") + (chosen.count > 3 ? "…" : ""),
                     clear: { selected.removeAll() }) {
            Toggle("Personal data too", isOn: $withData).toggleStyle(.switch).controlSize(.small)
                .help("Also remove the app's documents and settings Mole finds")
            Toggle("Skip Trash", isOn: $permanent).toggleStyle(.switch).controlSize(.small)
                .help("Delete for good instead of moving to the Trash")
            Button("Preview") {
                model.run("Preview uninstall", ["uninstall", "--dry-run"] + flags + names, plan: chosenBytes)
            }
            .buttonStyle(.pillSecondary)
            .help("See every file Mole would remove, without removing anything")
            Button("Uninstall") { askToUninstall() }.buttonStyle(.pill)
        }
    }

    private var names: [String] { chosen.map(\.uninstall_name) }
    private var flags: [String] { (withData ? ["--with-data"] : []) + (permanent ? ["--permanent"] : []) }

    private func askToUninstall() {
        confirm = .init(title: "Uninstall \(chosen.count) app\(chosen.count == 1 ? "" : "s")?",
                        message: permanent ? "Apps and their leftovers are deleted for good. Mole shows the full list and asks once more." :
                            "Apps and their leftovers go to the Trash, so you can still restore them. Mole shows the full list and asks once more.",
                        button: "Uninstall") {
            model.run("Uninstalling", ["uninstall"] + flags + names, plan: chosenBytes) {
                selected.removeAll()
                Task {
                    await catalog.load()
                    await leftovers.load()
                }
            }
        }
    }
}

private struct AppTile: View {
    let app: InstalledApp
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        SelectTile(selected: selected, glow: .ember, toggle: toggle) {
            AppIcon(path: app.path, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Text(app.bytes.map(\.bytesText) ?? "Size unknown").caption().monospacedDigit()
            }
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(app.path, inFileViewerRootedAtPath: "") }
            if let id = app.bundle_id { Text(id) }
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused(focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Capsule().fill(.white.opacity(0.07)))
        .overlay(Pill().strokeBorder(focused.wrappedValue ? .white.opacity(0.3) : Theme.hairline))
        .help("Search (⌘F)")
    }
}
