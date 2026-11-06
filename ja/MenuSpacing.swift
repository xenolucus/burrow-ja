import SwiftUI

/// Spacing between every app's menu bar items. A macOS setting, so it survives quitting Burrow JA.
enum MenuSpacing {
    static let range = 0.0...24.0
    static let spacingKey = "NSStatusItemSpacing"
    static let paddingKey = "NSStatusItemSelectionPadding"

    static func read(_ key: String) -> Int? {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
    }

    /// nil removes the key, which restores macOS's own value.
    static func write(_ key: String, _ value: Int?) {
        CFPreferencesSetValue(key as CFString, value as CFNumber?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    static func label(_ value: Int?) -> String { value.map { "\($0) pt" } ?? "標準" }
}

struct MenuSpacingCard: View {
    @ViewState private var spacing = MenuSpacing.read(MenuSpacing.spacingKey)
    @ViewState private var padding = MenuSpacing.read(MenuSpacing.paddingKey)
    @ViewState private var changed = false

    var body: some View {
        GlowCard(glow: .blue, style: .rim, padding: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("メニューバーの間隔").cardTitle()
                    Spacer()
                    Button("標準に戻す") {
                        spacing = nil
                        padding = nil
                        MenuSpacing.write(MenuSpacing.spacingKey, nil)
                        MenuSpacing.write(MenuSpacing.paddingKey, nil)
                        changed = true
                    }
                    .buttonStyle(.pillSecondary)
                    .disabled(spacing == nil && padding == nil)
                }
                Text("すべてのアプリの項目に効きます。下の見本はスライダーに合わせて動きます。").caption()
                preview
                slider("項目の間隔", $spacing, key: MenuSpacing.spacingKey)
                slider("クリック範囲の余白", $padding, key: MenuSpacing.paddingKey)
                if changed { Text("反映するには、ログアウトしてログインし直してください。").caption() }
            }
        }
    }

    /// A drawn copy of the menu bar, because the real one only changes after logging in again.
    private var preview: some View {
        let gap = CGFloat(spacing ?? 16), inset = CGFloat(padding ?? 16)
        let samples = ["calendar", "bolt.fill", "battery.75percent", "globe", "switch.2", "clock"]
        return HStack(spacing: gap) {
            Spacer(minLength: 0)
            ForEach(Array(samples.enumerated()), id: \.offset) { index, symbol in
                Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                    .frame(width: 22, height: 22)
                    .padding(.horizontal, inset / 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(index == 0 ? 0.2 : 0)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
        .clipped()
        .accessibilityLabel("メニューバーの見本。左端は選択中の範囲です。")
    }

    private func slider(_ title: String, _ value: Binding<Int?>, key: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).frame(width: 150, alignment: .leading)
            Slider(value: Binding { Double(value.wrappedValue ?? 16) } set: { value.wrappedValue = Int($0) },
                   in: MenuSpacing.range, step: 1) { editing in
                guard !editing else { return }
                MenuSpacing.write(key, value.wrappedValue)
                changed = true
            }
            .accessibilityLabel(title)
            Text(MenuSpacing.label(value.wrappedValue)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                .frame(width: 50, alignment: .trailing)
        }
    }
}
