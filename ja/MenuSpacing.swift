import SwiftUI

/// Spacing between every app's menu bar items. A macOS setting, so it survives quitting Burrow JA.
enum MenuSpacing: String, CaseIterable, Identifiable {
    case standard, narrow, minimum

    private static let spacingKey = "NSStatusItemSpacing" as CFString
    private static let paddingKey = "NSStatusItemSelectionPadding" as CFString

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "標準"
        case .narrow: "狭い"
        case .minimum: "最小"
        }
    }

    /// nil removes the keys, which restores macOS's own spacing.
    var values: (spacing: Int, padding: Int)? {
        switch self {
        case .standard: nil
        case .narrow: (8, 6)
        case .minimum: (4, 4)
        }
    }

    static func matching(spacing: Int?) -> MenuSpacing {
        allCases.first { $0.values?.spacing == spacing } ?? .standard
    }

    static var current: MenuSpacing {
        let value = CFPreferencesCopyValue(spacingKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return matching(spacing: value as? Int)
    }

    func apply() {
        let set = { (key: CFString, value: Int?) in
            CFPreferencesSetValue(key, value as CFNumber?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        set(Self.spacingKey, values?.spacing)
        set(Self.paddingKey, values?.padding)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }
}

struct MenuSpacingCard: View {
    @ViewState private var spacing = MenuSpacing.current
    @ViewState private var changed = false

    var body: some View {
        GlowCard(glow: .blue, style: .rim, padding: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("メニューバーの間隔").cardTitle()
                Text("すべてのアプリの項目の間隔を変えます。「標準」で元に戻せます。").caption()
                Picker("間隔", selection: $spacing) {
                    ForEach(MenuSpacing.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                .onChange(of: spacing) { _, value in
                    value.apply()
                    changed = true
                }
                if changed { Text("反映するには、ログアウトしてログインし直してください。").caption() }
            }
        }
    }
}
