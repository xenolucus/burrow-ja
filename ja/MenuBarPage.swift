import SwiftUI

/// Everything about the menu bar in one page, split into tabs so no tab has to scroll far.
struct MenuBarPage: View {
    private enum Tab: String { case values, spacing, groups }

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var hider = MenuHider.shared
    @AppStorage("menubar.tab") private var tab = Tab.values.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PillPicker(selection: $tab, options: [("値の表示", Tab.values.rawValue), ("項目の間隔", Tab.spacing.rawValue),
                                                  ("まとめ", Tab.groups.rawValue)])
            switch Tab(rawValue: tab) ?? .values {
            case .values:
                MenuMetricsCard(monitor: model.status)
                MenuTweakCard()
            case .spacing: MenuSpacingCard()
            case .groups:
                if hider.enabled {
                    MenuHideCard()
                } else {
                    EmptyState(symbol: "square.grid.2x2", text: "まとめは試験的な機能です。",
                               detail: "「設定」の「試験的な機能」でオンにします。", actionTitle: "設定を開く") { model.page = .settings }
                }
            }
        }
    }
}
