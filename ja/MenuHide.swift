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

    struct App: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: NSImage
    }

    /// Apps that can be hidden: those with a menu bar item, in name order.
    @Published private(set) var shownApps: [App] = []
    @Published private(set) var hiddenApps: [App] = []
    /// Without Accessibility the list falls back to every third-party app.
    @Published private(set) var canSeeMenuBar = AXIsProcessTrusted()

    /// macOS's own items are not apps' to hide, and hiding them is the private call's business.
    nonisolated static func listable(_ id: String, own: String?) -> Bool {
        id != own && !id.hasPrefix("com.apple.")
    }

    /// Asks the app itself, because `MenuBarAgent` lists only what is on screen right now.
    private nonisolated static func hasMenuBarItem(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        var count: CFIndex = 0
        AXUIElementGetAttributeValueCount(bar as! AXUIElement, kAXChildrenAttribute as CFString, &count)
        return count > 0
    }

    func askForAccessibility() {
        canSeeMenuBar = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func app(_ running: NSRunningApplication?, id: String) -> App {
        let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let name = running?.localizedName ?? url.map { FileManager.default.displayName(atPath: $0.path) } ?? id
        return App(id: id, name: name, icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .applicationBundle))
    }

    private func sorted(_ apps: [App]) -> [App] {
        apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Off the main thread: each ask is an IPC that waits for the app.
    func refreshApps() {
        canSeeMenuBar = AXIsProcessTrusted()
        let own = Bundle.main.bundleIdentifier, trusted = canSeeMenuBar
        var seen = Set<String>()
        let running = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy != .prohibited && app.bundleIdentifier.map { Self.listable($0, own: own) && seen.insert($0).inserted } == true
        }
        let candidates = running.map { ($0.bundleIdentifier ?? "", $0.processIdentifier) }
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                Set(candidates.filter { !trusted || Self.hasMenuBarItem(pid: $0.1) }.map(\.0))
            }.value
            shownApps = sorted(running.filter { found.contains($0.bundleIdentifier ?? "") && !hidden.contains($0.bundleIdentifier ?? "") }
                .map { app($0, id: $0.bundleIdentifier ?? "") })
            hiddenApps = sorted(hidden.map { id in app(running.first { $0.bundleIdentifier == id }, id: id) })
        }
    }

    func start() {
        guard enabled else { return }
        guard #available(macOS 27.0, *), Self.installedInApplications else {
            problem = "macOS 27 以降で、/Applications から起動したときだけ使えます。"
            return
        }
        refreshApps()
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
        refreshApps()
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
                MainActor.assumeIsolated {
                    self?.apply()
                    self?.refreshApps()
                }
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

    private func section(_ title: String, _ apps: [MenuHider.App], action: String, empty: String,
                         run: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title)（\(apps.count)）").font(.system(size: 13, weight: .semibold))
            if apps.isEmpty { Text(empty).caption() }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(apps) { app in
                    Button { run(app.id) } label: {
                        HStack(spacing: 6) {
                            Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                            Text(app.name).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(action).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(app.name) を\(action)")
                }
            }
        }
    }

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
                    if !hider.canSeeMenuBar {
                        HStack {
                            Text("アクセシビリティを許可すると、メニューバーに項目があるアプリだけを表示します。").caption()
                            Spacer()
                            Button("許可する") { hider.askForAccessibility() }.buttonStyle(.pillSecondary)
                        }
                    }
                    section("非表示中", hider.hiddenApps, action: "戻す", empty: "まだありません。") { hider.setHidden($0, false) }
                    section("表示中", hider.shownApps, action: "隠す", empty: "隠せるアプリは見つかりませんでした。") { hider.setHidden($0, true) }
                    Text("macOS の項目（Wi-Fi、コントロールセンターなど）は対象外です。").caption()
                }
            }
        }
        .onAppear { hider.refreshApps() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in hider.refreshApps() }
    }
}
