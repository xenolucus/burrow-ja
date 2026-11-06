import SwiftUI
import UserNotifications

/// Tells the user when space runs low or a clean would free a lot. Nothing is ever removed from here.
enum DiskAlert {
    static let lowKey = "alertLowDisk"
    static let lowGBKey = "alertLowDiskGB"
    static let checkDaysKey = "alertCheckDays"
    static let checkGBKey = "alertCheckGB"
    static let skipCleanConfirmKey = "skipCleanConfirm"
    private static let lastLowKey = "alertLastLow"
    private static let lastCheckKey = "alertLastCheck"
    static let defaultLowGB = 20
    static let defaultCheckGB = 5

    static func isDue(last: Date?, every seconds: TimeInterval, now: Date) -> Bool {
        last.map { now.timeIntervalSince($0) >= seconds } ?? true
    }

    private static func gigabytes(_ value: Int) -> Int64 { Int64(value) * 1_000_000_000 }

    private static func freeBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    private static func notify(_ title: String, _ body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: title, content: content, trigger: nil))
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    private static func checkLowDisk() async {
        let defaults = UserDefaults.standard
        let limit = defaults.object(forKey: lowGBKey) as? Int ?? defaultLowGB
        guard defaults.bool(forKey: lowKey), let free = freeBytes(), free < gigabytes(limit),
              isDue(last: defaults.object(forKey: lastLowKey) as? Date, every: 86400, now: Date()) else { return }
        defaults.set(Date(), forKey: lastLowKey)
        await notify("空き容量が少なくなっています", "残り \(free.bytesText) です。Burrow JA で不要なファイルを確認できます。")
    }

    @MainActor private static func checkCleanable(_ model: AppModel) async {
        let defaults = UserDefaults.standard
        let days = defaults.integer(forKey: checkDaysKey)
        guard days > 0, model.session == nil,
              isDue(last: defaults.object(forKey: lastCheckKey) as? Date, every: Double(days) * 86400, now: Date()),
              let data = try? await Mole.capture(["clean", "--dry-run"]) else { return }
        defaults.set(Date(), forKey: lastCheckKey)
        let bytes = SectionReport.parse(String(decoding: data, as: UTF8.self)).total
        let limit = defaults.object(forKey: checkGBKey) as? Int ?? defaultCheckGB
        if bytes >= gigabytes(limit) { await notify("クリーンできる項目があります", "\(bytes.bytesText) を空けられます。") }
    }

    /// Runs for the life of the app.
    @MainActor static func watch(_ model: AppModel) async {
        while !Task.isCancelled {
            await checkLowDisk()
            await checkCleanable(model)
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}

/// The menu bar icon is the only way back to a closed window, so the Dock icon stays while that is off.
enum DockIcon {
    static let hiddenKey = "hideDockIcon"

    static func policy(hidden: Bool, inMenuBar: Bool) -> NSApplication.ActivationPolicy {
        hidden && inMenuBar ? .accessory : .regular
    }

    @MainActor static func apply() {
        let defaults = UserDefaults.standard
        NSApp.setActivationPolicy(policy(hidden: defaults.bool(forKey: hiddenKey), inMenuBar: defaults.bool(forKey: "showInMenuBar")))
        // Changing the policy can send the window behind other apps.
        NSApp.activate()
        NSApp.burrowWindow?.makeKeyAndOrderFront(nil)
    }
}

struct AlertsCard: View {
    @AppStorage(DiskAlert.lowKey) private var low = false
    @AppStorage(DiskAlert.lowGBKey) private var lowGB = DiskAlert.defaultLowGB
    @AppStorage(DiskAlert.checkDaysKey) private var checkDays = 0
    @AppStorage(DiskAlert.checkGBKey) private var checkGB = DiskAlert.defaultCheckGB
    @AppStorage(DiskAlert.skipCleanConfirmKey) private var skipConfirm = false
    @AppStorage(DockIcon.hiddenKey) private var hideDock = false
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @ViewState private var denied = false

    var body: some View {
        GlowCard(glow: .ember, style: .rim, padding: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("通知と動作").cardTitle()
                Toggle("空き容量が少ないときに通知", isOn: Binding { low } set: { on in
                    low = on
                    if on { ask() }
                })
                if low {
                    picker("通知する空き容量", selection: $lowGB, values: [10, 20, 50, 100])
                }
                HStack(spacing: 12) {
                    Text("クリーンできる量の確認").font(.system(size: 13))
                    Picker("クリーンできる量の確認", selection: Binding { checkDays } set: { days in
                        checkDays = days
                        if days > 0 { ask() }
                    }) {
                        Text("しない").tag(0)
                        Text("毎日").tag(1)
                        Text("毎週").tag(7)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 240)
                }
                if checkDays > 0 {
                    picker("通知するクリーン可能量", selection: $checkGB, values: [1, 5, 10, 50])
                }
                Text("確認だけを行い、自動では削除しません。アプリが起動している間に動きます。").caption()
                if denied {
                    Text("通知が許可されていません。「システム設定」の「通知」で Burrow JA をオンにしてください。")
                        .font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
                Toggle("クリーン前の確認を省略", isOn: $skipConfirm)
                Text("「今すぐクリーン」を押すとすぐに始まります。「Mole が残した項目」の削除は常に確認します。").caption()
                Toggle("Dock にアイコンを表示しない", isOn: $hideDock)
                Text("アプリはメニューバーのアイコンから開きます。「メニューバーに表示」がオフの間は Dock に表示します。").caption()
            }
            .font(.system(size: 13)).toggleStyle(.switch).controlSize(.small)
        }
        .onChange(of: hideDock) { DockIcon.apply() }
        .onChange(of: showInMenuBar) { DockIcon.apply() }
    }

    private func picker(_ title: String, selection: Binding<Int>, values: [Int]) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13))
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { Text("\($0) GB").tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 240)
        }
    }

    private func ask() {
        Task { denied = !(await DiskAlert.requestPermission()) }
    }
}
