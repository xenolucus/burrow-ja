import ServiceManagement
import SwiftUI

/// A line-based Mole config file (`whitelist`, `purge_paths`): comments are kept as they are.
struct ConfigList {
    let url: URL

    static let whitelist = ConfigList(url: home(".config/mole/whitelist"))
    static let purgePaths = ConfigList(url: home(".config/mole/purge_paths"))

    /// "~", "~/", "$HOME", "/Users/me/" and the like all name the home folder.
    static func isHome(_ entry: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let expanded = (entry.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
                        as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path == home
    }

    static func home(_ path: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
    }

    func read() -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func write(_ entries: [String]) {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let comments = text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.hasPrefix("#") }
        let body = (comments.map(String.init) + (comments.isEmpty ? [] : [""]) + entries).joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct SettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var whitelist: [String] = []
    @ViewState private var purgePaths: [String] = []
    /// The last known state, so a return visit does not show a spinner while it is checked again.
    private static var knownTouchID: Bool?
    /// nil while checking.
    @ViewState private var touchID: Bool? = SettingsPage.knownTouchID
    @AppStorage(RemovalWatcher.enabledKey) private var offerLeftovers = true
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @ViewState private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                PathListCard(title: "Protected paths",
                             caption: "Clean, Optimize and Slim never touch these. Wildcards like * work.",
                             glow: .sage, entries: $whitelist) { ConfigList.whitelist.write($0) }
                PathListCard(title: "Project scan folders",
                             caption: "Where Projects looks for build folders.",
                             warning: purgePaths.contains(where: ConfigList.isHome)
                                ? "Your whole home folder is slow to scan and can time out. Project folders work best." : "",
                             glow: .blue, entries: $purgePaths) { ConfigList.purgePaths.write($0) }
            }
            // Cards in a row share the height of the taller one's content, never a fixed height.
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 18) {
                GlowCard(glow: .violet, style: .core) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Touch ID for admin steps", systemImage: "touchid").cardTitle()
                            Spacer()
                            switch touchID {
                            case true?: Tag(text: "On", color: Theme.accent)
                            case false?: Tag(text: "Off")
                            case nil: PulseDot(color: .white)
                            }
                        }
                        Text("Approve Mole's administrator steps with your fingerprint instead of typing the password. Changing it asks for your password once.").caption()
                        Spacer(minLength: 0)
                        if let on = touchID {
                            Button(on ? "Turn off" : "Turn on") {
                                model.run("Touch ID for sudo", ["touchid", on ? "disable" : "enable"]) {
                                    touchID = nil
                                    Task { await checkTouchID() }
                                }
                            }
                            .buttonStyle(on ? .pillSecondary : .pill)
                        }
                    }
                }

                GlowCard(glow: .graphite, style: .plain) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("About").cardTitle()
                        Text("A free, open-source window for Mole \(Mole.version), the macOS cleaner by tw93. Clean, Uninstall, Optimize, Slim and removing all build folders run through Mole and its safety checks; installers, single build folders and Disk Map items you pick go to the Trash.").caption()
                        Text("Licensed GPL-3.0, like Mole.").caption()
                        Spacer(minLength: 0)
                        HStack {
                            Link("Mole on GitHub", destination: URL(string: "https://github.com/tw93/Mole")!)
                                .buttonStyle(.pillSecondary)
                            Button("Mole's logs") {
                                NSWorkspace.shared.open(ConfigList.home("Library/Logs/mole"))
                            }
                            .buttonStyle(.pillSecondary)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            GlowCard(glow: .ember, style: .rim, padding: 22) {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("When you delete an app").cardTitle()
                        Text("Burrow spots the files a deleted app leaves behind and offers to move them to the Trash. To notice in time, it keeps running after you close its window.").caption()
                            .frame(maxWidth: 520, alignment: .leading)
                    }
                    Spacer()
                    Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Offer to clean up").font(.system(size: 13))
                            Toggle("Offer to clean up", isOn: $offerLeftovers).labelsHidden()
                        }
                        GridRow {
                            Text("Show in menu bar").font(.system(size: 13))
                            Toggle("Show in menu bar", isOn: $showInMenuBar).labelsHidden()
                        }
                        GridRow {
                            Text("Start Burrow at login").font(.system(size: 13))
                            Toggle("Start Burrow at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin)).labelsHidden()
                        }
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    .fixedSize()
                }
            }
        }
        .task {
            whitelist = ConfigList.whitelist.read()
            purgePaths = ConfigList.purgePaths.read()
            await checkTouchID()
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func checkTouchID() async {
        let out = String(decoding: (try? await Mole.capture(["touchid", "status"])) ?? Data(), as: UTF8.self)
        touchID = out.contains("is enabled")
        Self.knownTouchID = touchID
    }
}

private struct PathListCard: View {
    let title: String
    let caption: String
    var warning = ""
    let glow: Glow
    @Binding var entries: [String]
    let save: ([String]) -> Void
    @ViewState private var draft = ""

    var body: some View {
        GlowCard(glow: glow, style: .plain) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).cardTitle()
                Text(caption).caption()
                if !warning.isEmpty {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                }
                HStack {
                    TextField("Add a path", text: $draft)
                        .textFieldStyle(.plain).padding(.horizontal, 12).frame(height: 32)
                        .background(Capsule().fill(.white.opacity(0.07)))
                        .onSubmit(add)
                    CircleIconButton(symbol: "folder.badge.plus", help: "Choose a folder") { choose() }
                }
                VStack(spacing: 6) {
                    if entries.isEmpty {
                        Text("None yet").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12).frame(height: 30)
                    }
                    ForEach(entries, id: \.self) { entry in
                        HStack {
                            Text((entry as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                withAnimation(Motion.quick) { entries.removeAll { $0 == entry } }
                                save(entries)
                            } label: {
                                Image(systemName: "minus.circle.fill").frame(width: 24, height: 24).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).foregroundStyle(Theme.secondaryText)
                            .help("Remove")
                            .accessibilityLabel("Remove \(entry)")
                        }
                        .padding(.leading, 12).padding(.trailing, 4).frame(height: 30)
                        .background(Capsule().fill(.white.opacity(0.05)))
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func add() {
        let path = draft.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !entries.contains(path) else { return }
        withAnimation(Motion.quick) { entries.append(path) }
        save(entries)
        draft = ""
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            draft = url.path
            add()
        }
    }
}
