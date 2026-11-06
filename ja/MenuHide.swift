import AppKit
import SwiftUI

// Hiding on macOS 27 is adapted from Ellipsis by Ronny Haryanto (Apache-2.0),
// https://github.com/ronny/ellipsis, commit f5a5d39. See LICENSE-Ellipsis.txt.

/// What an assertion allows, so a call that would change nothing does nothing.
struct HideList: Equatable {
    var hidden: Set<String>
    var allowed: Set<String>

    static func make(running: [String], hidden: Set<String>) -> HideList {
        HideList(hidden: hidden, allowed: Set(running).subtracting(hidden))
    }
}

enum MenuHideError: LocalizedError {
    case unavailable

    var errorDescription: String? { "この macOS では項目を隠す機能が見つかりません。" }
}

/// One assessment-mode assertion against `MenuBarAgent`, the only way to hide other apps' items
/// on macOS 27. A private framework, looked up at run time so a macOS update only disables this.
@MainActor
final class MenuBarRestriction {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    /// System items by code; codes past the end are ignored, so this keeps every one visible.
    private static let systemItems = (0...40).map { NSNumber(value: $0) }

    private let configurationClass: NSObject.Type
    private let assertionClass: NSObject.Type
    private var assertion: NSObject?
    private var current: HideList?

    init() throws {
        guard dlopen(Self.frameworkPath, RTLD_NOW) != nil,
              let configurationClass = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
              let assertionClass = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type
        else { throw MenuHideError.unavailable }
        self.configurationClass = configurationClass
        self.assertionClass = assertionClass
    }

    /// The newest assertion wins, so the old one stays until the new one reports back:
    /// dropping it earlier makes every item flash.
    func apply(_ list: HideList) {
        guard list != current else { return }
        current = list
        let configuration = (configurationClass as AnyObject)
            .perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
            .perform(NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:"),
                     with: Self.systemItems as NSArray, with: list.allowed.sorted() as NSArray)?
            .takeUnretainedValue()
        let next = assertionClass.init()
        nonisolated(unsafe) let previous = assertion
        let completion: @convention(block) (Any?) -> Void = { _ in
            _ = previous?.perform(NSSelectorFromString("invalidate"))
        }
        _ = next.perform(NSSelectorFromString("activateWithConfiguration:completionHandler:"), with: configuration, with: completion)
        assertion = next
    }

    func release() {
        _ = assertion?.perform(NSSelectorFromString("invalidate"))
        assertion = nil
        current = nil
    }
}

@MainActor
final class MenuHider: ObservableObject {
    static let shared = MenuHider()
    private static let enabledKey = "experimentalMenuHide"
    private static let hiddenKey = "menuHiddenApps"
    private static let revealSeconds = 30

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
    @Published private(set) var revealed = false
    @Published private(set) var problem: String?

    private var restriction: MenuBarRestriction?
    private var revealTask: Task<Void, Never>?
    private var watching = false

    /// macOS only allows the private call for apps in /Applications.
    static var installedInApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    struct App: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
    }

    var runningApps: [App] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app -> App? in
            guard app.activationPolicy != .prohibited, let id = app.bundleIdentifier, id != own,
                  seen.insert(id).inserted else { return nil }
            return App(id: id, name: app.localizedName ?? id, icon: app.icon ?? NSImage())
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var hiddenApps: [App] { runningApps.filter { hidden.contains($0.id) } }

    func start() {
        guard enabled else { return }
        guard #available(macOS 27.0, *), Self.installedInApplications else {
            problem = "macOS 27 以降で、/Applications から起動したときだけ使えます。"
            return
        }
        do {
            restriction = try restriction ?? MenuBarRestriction()
            watchApps()
            apply()
        } catch {
            problem = error.localizedDescription
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        problem = nil
        if on { start() } else { restriction?.release() }
    }

    func setHidden(_ id: String, _ on: Bool) {
        if on { hidden.insert(id) } else { hidden.remove(id) }
        UserDefaults.standard.set(hidden.sorted(), forKey: Self.hiddenKey)
        apply()
    }

    /// Shows the real items for a moment, then hides them again by itself.
    func reveal() {
        revealed = true
        apply()
        revealTask?.cancel()
        revealTask = Task {
            try? await Task.sleep(for: .seconds(Self.revealSeconds))
            guard !Task.isCancelled else { return }
            revealed = false
            apply()
        }
    }

    func open(_ id: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
    }

    private func apply() {
        guard enabled, !revealed, !hidden.isEmpty else { return restriction?.release() ?? () }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        restriction?.apply(.make(running: running, hidden: hidden))
    }

    /// The allow-list is a snapshot, so an app that starts later needs a new one to stay visible.
    private func watchApps() {
        guard !watching else { return }
        watching = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }
    }
}

/// The one place every hidden app lives: a row in the menu bar card.
struct HiddenAppsRow: View {
    @ObservedObject private var hider = MenuHider.shared

    var body: some View {
        if hider.enabled, !hider.hidden.isEmpty {
            HStack(spacing: 6) {
                ForEach(hider.hiddenApps) { app in
                    Button { hider.open(app.id) } label: {
                        Image(nsImage: app.icon).resizable().frame(width: 22, height: 22).padding(3)
                    }
                    .buttonStyle(.plain).help(app.name).accessibilityLabel(app.name)
                }
                Spacer(minLength: 0)
                Button(hider.revealed ? "表示中" : "30秒表示") { hider.reveal() }
                    .font(.system(size: 12)).buttonStyle(.link).disabled(hider.revealed)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
        }
    }
}

struct MenuHideCard: View {
    @ObservedObject private var hider = MenuHider.shared

    var body: some View {
        GlowCard(glow: .ember, style: .rim, padding: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("メニューバー項目をまとめる（試験的）").cardTitle()
                    Spacer()
                    Toggle("オン", isOn: Binding { hider.enabled } set: { hider.setEnabled($0) })
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Text("選んだアプリの項目を隠し、メニューバーのカードにまとめます。隠している間は、集中モードとカメラ・マイクの表示も隠れ、時計やバッテリーがクリックできなくなる場合があります。").caption()
                if let problem = hider.problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
                if hider.enabled {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(hider.runningApps) { app in
                            Toggle(isOn: Binding { hider.hidden.contains(app.id) } set: { hider.setHidden(app.id, $0) }) {
                                HStack(spacing: 6) {
                                    Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                                    Text(app.name).font(.system(size: 13)).lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
    }
}
