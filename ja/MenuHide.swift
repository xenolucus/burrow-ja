import AppKit
import ScreenCaptureKit
import SwiftUI

// Hiding on macOS 27 is adapted from Ellipsis by Ronny Haryanto (Apache-2.0),
// https://github.com/ronny/ellipsis, commit f5a5d39. See LICENSE-Ellipsis.txt.

/// What an assertion allows, so a call that would change nothing does nothing.
struct HideList: Equatable {
    var hidden: Set<String>
    var allowed: Set<String>

    /// `own` is always allowed: right after launch the app may not be in the running list yet,
    /// and leaving it out hides its own menu bar items.
    static func make(running: [String], hidden: Set<String>, own: String?) -> HideList {
        HideList(hidden: hidden, allowed: Set(running + [own].compactMap { $0 }).subtracting(hidden))
    }
}

/// One icon in the menu bar and the apps gathered under it.
struct MenuGroup: Codable, Identifiable, Equatable {
    static let symbols = ["square.grid.2x2", "folder", "tray.full", "star", "bolt", "briefcase",
                          "gamecontroller", "paintbrush", "music.note", "message", "wrench.and.screwdriver", "ellipsis.circle"]

    var id = UUID().uuidString
    var name = "まとめ"
    var symbol = symbols[0]
    var apps: [String] = []

    /// Saved groups, or one group holding what an older version hid.
    static func load(saved: Data?, legacy: [String]) -> [MenuGroup] {
        if let saved, let groups = try? JSONDecoder().decode([MenuGroup].self, from: saved), !groups.isEmpty { return groups }
        return [MenuGroup(apps: legacy)]
    }
}

/// The status items, made by hand because SwiftUI scenes cannot repeat at run time.
@MainActor
final class MenuGroupBar: NSObject {
    private var items: [String: NSStatusItem] = [:]
    private let popover = NSPopover()

    func sync(_ groups: [MenuGroup], expanded: Set<String> = []) {
        for id in Set(items.keys).subtracting(groups.map(\.id)) {
            items.removeValue(forKey: id).map(NSStatusBar.system.removeStatusItem)
        }
        for group in groups {
            // Wider than a square, because a tight system spacing otherwise joins it to the next item.
            let item = items[group.id] ?? NSStatusBar.system.statusItem(withLength: 32)
            items[group.id] = item
            let open = expanded.contains(group.id)
            let symbol = open ? NSImage(systemSymbolName: group.symbol + ".fill", accessibilityDescription: group.name) : nil
            item.button?.image = symbol ?? NSImage(systemSymbolName: group.symbol, accessibilityDescription: group.name)
            item.button?.image?.isTemplate = true
            item.button?.toolTip = group.name
            item.button?.identifier = NSUserInterfaceItemIdentifier(group.id)
            item.button?.target = self
            item.button?.action = #selector(clicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// A left click opens the group right in the menu bar; a right click lists it in a panel.
    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type != .rightMouseUp {
            popover.performClose(nil)
            MenuHider.shared.toggleGroup(sender.identifier?.rawValue ?? "")
            return
        }
        if popover.isShown { return popover.performClose(nil) }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuGroupView(groupID: sender.identifier?.rawValue ?? "") { [weak self] in
            self?.popover.performClose(nil)
        })
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
}

/// Lifts a menu bar item out of its screenshot: removes the wallpaper showing through the bar,
/// turns dark glyphs light for the dark panel, and trims the empty sides.
enum MenuIconCleaner {
    private static let solid = 60, clear = 18

    /// RGBA pixels of an opaque picture become premultiplied RGBA with a clear background.
    static func clean(_ pixels: inout [UInt8], width: Int, height: Int) {
        var glyph = 0, glyphCount = 0, backdrop = 0
        for y in 0..<height {
            let row = y * width * 4, last = row + (width - 1) * 4
            // The bar is a vertical gradient, so each row has its own background.
            let edge = (0..<3).map { (Int(pixels[row + $0]) + Int(pixels[last + $0])) / 2 }
            backdrop += edge.reduce(0, +) / 3
            for x in 0..<width {
                let i = row + x * 4
                let color = (0..<3).map { Int(pixels[i + $0]) }
                let distance = (0..<3).map { abs(color[$0] - edge[$0]) }.max() ?? 0
                let alpha = min(max(distance - clear, 0) * 255 / (solid - clear), 255)
                for c in 0..<3 {
                    pixels[i + c] = UInt8(min(max(color[c] - (255 - alpha) * edge[c] / 255, 0), alpha))
                }
                pixels[i + 3] = UInt8(alpha)
                if alpha > 128 {
                    glyph += color.reduce(0, +) / 3
                    glyphCount += 1
                }
            }
        }
        guard glyphCount > 0, glyph / glyphCount < backdrop / max(height, 1) else { return }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let (r, g, b) = (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
            guard max(r, g, b) - min(r, g, b) < 40 else { continue }  // leave coloured badges alone
            for c in 0..<3 { pixels[i + c] = UInt8(max(Int(pixels[i + 3]) - Int(pixels[i + c]), 0)) }
        }
    }

    static func clean(_ image: CGImage, scale: CGFloat) -> NSImage? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let space = CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: info)?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        clean(&pixels, width: width, height: height)
        let columns = (0..<width).filter { x in (0..<height).contains { pixels[($0 * width + x) * 4 + 3] > 24 } }
        let rows = (0..<height).filter { y in (0..<width).contains { pixels[(y * width + $0) * 4 + 3] > 24 } }
        guard let left = columns.first, let right = columns.last, let top = rows.first, let bottom = rows.last else { return nil }
        let result = pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: info)?.makeImage()
        }
        let box = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        guard let trimmed = result?.cropping(to: box) else { return nil }
        return NSImage(cgImage: trimmed, size: NSSize(width: box.width / scale, height: box.height / scale))
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
    private static let legacyHiddenKey = "menuHiddenApps"
    private static let groupsKey = "menuGroups"
    private static let revealSeconds = 30

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var groups = MenuGroup.load(saved: UserDefaults.standard.data(forKey: groupsKey),
                                                        legacy: UserDefaults.standard.stringArray(forKey: legacyHiddenKey) ?? [])
    private let bar = MenuGroupBar()
    /// Pictures of the real menu bar items. macOS 27 keeps no per-item window to read them from.
    @Published private(set) var itemIcons: [String: NSImage] = [:]
    var hidden: Set<String> { Set(groups.flatMap(\.apps)) }
    @Published private(set) var revealed = false
    @Published private(set) var problem: String?

    private var restriction: MenuBarRestriction?
    private var revealTask: Task<Void, Never>?
    private var pressTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var roomTask: Task<Void, Never>?
    /// macOS folded items away, so everything else steps aside while a group is open.
    private var makingRoom = false
    /// Groups opened from their icon, whose apps are back in the menu bar for now.
    @Published private(set) var expanded = Set<String>()
    /// Seconds an opened group stays open; 0 keeps it open until clicked again.
    static let collapseKey = "menuCollapseSeconds"
    static let defaultCollapse = 15
    /// The hidden app let through for a moment, so its item can be pressed.
    private var passing: String?
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
        bar.sync(groups)
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
        if on {
            start()
        } else {
            restriction?.release()
            bar.sync([])
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(groups), forKey: Self.groupsKey)
        if enabled { bar.sync(groups, expanded: expanded) }
        apply()
        refreshApps()
    }

    func addGroup() {
        groups.append(MenuGroup(name: "まとめ \(groups.count + 1)"))
        save()
    }

    /// Its apps return to the menu bar, and one group always remains.
    func removeGroup(_ id: String) {
        guard groups.count > 1 else { return }
        groups.removeAll { $0.id == id }
        save()
    }

    func updateGroup(_ id: String, _ change: (inout MenuGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        change(&groups[index])
        save()
    }

    func setHidden(_ app: String, _ on: Bool, in group: String) {
        for index in groups.indices { groups[index].apps.removeAll { $0 == app } }
        guard on else { return save() }
        Task {
            await captureIcons([app])  // while it is still drawn, so nothing flashes
            guard let index = groups.firstIndex(where: { $0.id == group }) else { return save() }
            groups[index].apps.append(app)
            save()
        }
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

    func toggleGroup(_ id: String) {
        if expanded.remove(id) == nil { expanded.insert(id) }
        makingRoom = false
        bar.sync(groups, expanded: expanded)
        apply()
        roomTask?.cancel()
        if expanded.contains(id) {
            roomTask = Task {
                // MenuBarAgent animates the new layout for about a second before it folds anything.
                try? await Task.sleep(for: .milliseconds(1200))
                let folded = await Task.detached(priority: .userInitiated) { Self.menuBarOverflows() }.value
                guard folded, !Task.isCancelled else { return }
                makingRoom = true
                apply()
            }
        }
        collapseTask?.cancel()
        let stored = UserDefaults.standard.object(forKey: Self.collapseKey) as? Int ?? Self.defaultCollapse
        guard stored > 0, !expanded.isEmpty else { return }
        collapseTask = Task {
            try? await Task.sleep(for: .seconds(stored))
            guard !Task.isCancelled else { return }
            expanded = []
            makingRoom = false
            bar.sync(groups)
            apply()
        }
    }

    /// The panel's click: shows just this app's item and presses it, so its own menu opens.
    /// shortcut: hides again after a fixed time, not when the menu closes; watch the menu to upgrade.
    private static func iconFile(_ id: String) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "burrow-ja").appendingPathComponent("menu-icons")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    func itemIcon(_ id: String) -> NSImage? {
        itemIcons[id] ?? NSImage(contentsOf: Self.iconFile(id))
    }

    /// Runs only on request or when an app is added, so the menu bar is never watched.
    /// Takes the item from the screen while it is drawn; a collapsed item keeps the app icon.
    func captureIcons(_ ids: [String]) async {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            problem = "実物のアイコンには画面収録の許可が必要です。許可してから「アイコンを更新」を押してください。"
            return
        }
        problem = nil
        for id in ids {
            let frame = await Task.detached(priority: .userInitiated) { Self.itemFrame(of: id) }.value
            guard let frame, let shot = try? await SCScreenshotManager.captureImage(in: frame) else { continue }
            guard let image = MenuIconCleaner.clean(shot, scale: CGFloat(shot.width) / frame.width),
                  let cleaned = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            itemIcons[id] = image
            let file = NSBitmapImageRep(cgImage: cleaned)
            file.size = image.size
            try? file.representation(using: .png, properties: [:])?.write(to: Self.iconFile(id), options: .atomic)
        }
    }

    /// Shows every hidden item for a moment, because only a drawn item can be pictured.
    func refreshIcons() {
        revealed = true
        apply()
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            await captureIcons(Array(hidden))
            revealed = false
            apply()
        }
    }

    func press(_ id: String) {
        pressTask?.cancel()
        passing = id
        apply()
        pressTask = Task {
            var pressed = false
            let deadline = ContinuousClock.now + .seconds(4)
            while !pressed, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                pressed = await Task.detached(priority: .userInitiated) { Self.pressMenuBarItem(of: id) }.value
            }
            if !pressed { NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate() }
            try? await Task.sleep(for: .seconds(Self.revealSeconds))
            guard !Task.isCancelled else { return }
            passing = nil
            apply()
        }
    }

    /// macOS draws a « button in a childless slot when items no longer fit.
    private nonisolated static func menuBarOverflows() -> Bool {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return false }
        func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
            return value as? [AXUIElement] ?? []
        }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        return children(app, kAXWindowsAttribute).contains { window in
            children(window, kAXChildrenAttribute).contains { slot in
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(slot, kAXRoleAttribute as CFString, &role)
                return children(slot, kAXChildrenAttribute).isEmpty && role as? String == kAXButtonRole
            }
        }
    }

    /// While making room, every other third-party app hides so the opened items fit.
    nonisolated static func withRoom(_ list: Set<String>, running: [String], keep: Set<String>, own: String?) -> Set<String> {
        list.union(running.filter { listable($0, own: own) && !keep.contains($0) })
    }

    private nonisolated static func pressMenuBarItem(of id: String) -> Bool {
        guard let owner = menuBarSlot(of: id)?.owner else { return false }
        AXUIElementSetMessagingTimeout(owner, 1)
        return AXUIElementPerformAction(owner, kAXPressAction as CFString) == .success
    }

    private nonisolated static func itemFrame(of id: String) -> CGRect? {
        guard let slot = menuBarSlot(of: id)?.slot else { return nil }
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(slot, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(slot, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return extent.width > 0 ? CGRect(origin: origin, size: extent) : nil
    }

    /// `MenuBarAgent` holds one window per display; each slot's child belongs to the app drawing it.
    private nonisolated static func menuBarSlot(of id: String) -> (slot: AXUIElement, owner: AXUIElement)? {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return nil }
        func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
            return value as? [AXUIElement] ?? []
        }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        for window in children(app, kAXWindowsAttribute) {
            for slot in children(window, kAXChildrenAttribute) {
                guard let owner = children(slot, kAXChildrenAttribute).first else { continue }
                var pid: pid_t = 0
                AXUIElementGetPid(owner, &pid)
                if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == id { return (slot, owner) }
            }
        }
        return nil
    }

    /// What stays hidden once `passing` and the opened groups' apps are let through.
    nonisolated static func stillHidden(_ groups: [MenuGroup], expanded: Set<String>, passing: String?) -> Set<String> {
        let opened = groups.filter { expanded.contains($0.id) }.flatMap(\.apps)
        return Set(groups.flatMap(\.apps)).subtracting(opened + [passing].compactMap { $0 })
    }

    private func apply() {
        guard enabled, !revealed, !hidden.isEmpty else { return restriction?.release() ?? () }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        var list = Self.stillHidden(groups, expanded: expanded, passing: passing)
        if makingRoom {
            let opened = Set(groups.filter { expanded.contains($0.id) }.flatMap(\.apps))
            list = Self.withRoom(list, running: running, keep: opened, own: Bundle.main.bundleIdentifier)
        }
        guard !list.isEmpty else { return restriction?.release() ?? () }
        restriction?.apply(.make(running: running, hidden: list, own: Bundle.main.bundleIdentifier))
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

/// The panel under a group's icon.
struct MenuGroupView: View {
    let groupID: String
    let close: () -> Void
    @ObservedObject private var hider = MenuHider.shared

    private var apps: [MenuHider.App] {
        let ids = hider.groups.first { $0.id == groupID }?.apps ?? []
        return hider.hiddenApps.filter { ids.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if apps.isEmpty {
                Text("「設定」でこのまとめにアプリを追加します。").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64)), count: 4), spacing: 8) {
                ForEach(apps) { app in
                    Button {
                        close()
                        hider.press(app.id)
                    } label: {
                        Group {
                            if let icon = hider.itemIcon(app.id) {
                                Image(nsImage: icon)
                            } else {
                                Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                            }
                        }
                        .frame(width: 60, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focusEffectDisabled().help(app.name).accessibilityLabel(app.name)
                }
            }
            if !apps.isEmpty {
                HStack {
                    Button(hider.revealed ? "表示中" : "すべて30秒表示") { hider.reveal() }
                        .disabled(hider.revealed)
                    Spacer()
                    Button("アイコンを更新") { hider.refreshIcons() }.disabled(hider.revealed)
                }
                .font(.system(size: 12)).buttonStyle(.link)
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .onAppear { hider.refreshApps() }
    }
}

struct MenuHideCard: View {
    @ObservedObject private var hider = MenuHider.shared
    @ViewState private var selectedID: String?
    @AppStorage(MenuHider.collapseKey) private var collapse = MenuHider.defaultCollapse

    private var selected: MenuGroup? { hider.groups.first { $0.id == selectedID } ?? hider.groups.first }

    private func groupEditor(_ group: MenuGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(hider.groups) { item in
                    Button { selectedID = item.id } label: {
                        Label(item.name, systemImage: item.symbol).font(.system(size: 12)).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(item.id == group.id ? 0.2 : 0.06)))
                    }
                    .buttonStyle(.plain)
                }
                Button { hider.addGroup() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).accessibilityLabel("まとめを追加")
                Spacer()
                if hider.groups.count > 1 {
                    Button("このまとめを削除") { hider.removeGroup(group.id) }.buttonStyle(.link).font(.system(size: 12))
                }
            }
            HStack(spacing: 8) {
                TextField("名前", text: Binding { group.name } set: { name in hider.updateGroup(group.id) { $0.name = name } })
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                ForEach(MenuGroup.symbols, id: \.self) { symbol in
                    Button { hider.updateGroup(group.id) { $0.symbol = symbol } } label: {
                        Image(systemName: symbol).font(.system(size: 13)).frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(symbol == group.symbol ? 0.22 : 0)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(symbol)
                }
            }
        }
    }

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
                Text("メニューバー項目のまとめ（試験的）").cardTitle()
                Text("アイコンを押すと、まとめたアプリがメニューバーに出ます。もう一度押すと隠れます。右クリックで一覧を開きます。隠している間は、集中モードとカメラ・マイクの表示も隠れ、時計やバッテリーがクリックできなくなる場合があります。").caption()
                if let problem = hider.problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
                do {
                    if !hider.canSeeMenuBar {
                        HStack {
                            Text("アクセシビリティを許可すると、メニューバーに項目があるアプリだけを表示します。").caption()
                            Spacer()
                            Button("許可する") { hider.askForAccessibility() }.buttonStyle(.pillSecondary)
                        }
                    }
                    HStack(spacing: 12) {
                        Text("自動で隠すまで").font(.system(size: 13))
                        Picker("自動で隠すまで", selection: $collapse) {
                            ForEach([5, 15, 30, 0], id: \.self) { Text($0 == 0 ? "隠さない" : "\($0)秒").tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                    }
                    if let group = selected {
                        groupEditor(group)
                        section("このまとめ", hider.hiddenApps.filter { group.apps.contains($0.id) }, action: "戻す", empty: "まだありません。") {
                            hider.setHidden($0, false, in: group.id)
                        }
                        section("表示中", hider.shownApps, action: "まとめる", empty: "まとめられるアプリは見つかりませんでした。") {
                            hider.setHidden($0, true, in: group.id)
                        }
                    }
                    Text("macOS の項目（Wi-Fi、コントロールセンターなど）は対象外です。").caption()
                }
            }
        }
        .onAppear { hider.refreshApps() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in hider.refreshApps() }
    }
}
