import SwiftUI

extension Page {
    static let orderKey = "sidebarOrder"
    static let hiddenKey = "sidebarHidden"
    /// Additions on top of Burrow, which anyone can remove from the app.
    static let extras: [Page] = [.drives, .duplicates, .menubar, .tools, .totals]
    private static let bottom: [Page] = [.history, .totals, .settings]

    /// The reorderable pages in `order`. A page the saved order does not know joins at the end,
    /// so an update that adds one never loses it.
    static func main(order: String, hidden: String) -> [Page] {
        let saved = order.split(separator: ",").compactMap { Page(rawValue: String($0)) }
        let all = saved + allCases.filter { !saved.contains($0) }
        let off = Set(hidden.split(separator: ",").map(String.init))
        return all.filter { !bottom.contains($0) && !off.contains($0.rawValue) }
    }

    static func sidebar(order: String, hidden: String) -> [Page] {
        let off = Set(hidden.split(separator: ",").map(String.init))
        return main(order: order, hidden: hidden) + bottom.filter { !off.contains($0.rawValue) }
    }

    static var current: [Page] {
        let defaults = UserDefaults.standard
        return sidebar(order: defaults.string(forKey: orderKey) ?? "", hidden: defaults.string(forKey: hiddenKey) ?? "")
    }

    static func isHidden(_ page: Page) -> Bool {
        (UserDefaults.standard.string(forKey: hiddenKey) ?? "").split(separator: ",").contains(Substring(page.rawValue))
    }

    /// The new order after moving `page` by `offset`, or nil at either end.
    static func moved(_ page: Page, by offset: Int, in order: [Page]) -> [Page]? {
        guard let index = order.firstIndex(of: page), order.indices.contains(index + offset) else { return nil }
        var result = order
        result.swapAt(index, index + offset)
        return result
    }
}

/// Sidebar order, and which additions are installed.
struct ContentCard: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(Page.orderKey) private var order = ""
    @AppStorage(Page.hiddenKey) private var hidden = ""

    private var pages: [Page] { Page.main(order: order, hidden: hidden) }

    var body: some View {
        GlowCard(glow: .sage, style: .rim, padding: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("サイドバー").cardTitle()
                    Spacer()
                    Button("標準の順に戻す") { order = "" }.buttonStyle(.link).font(.system(size: 12)).disabled(order.isEmpty)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 18, alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(pages) { page in row(page) }
                }
                Text("追加コンテンツ").font(.system(size: 13, weight: .semibold))
                Text("元の Burrow にない機能です。不要なら外せます。").caption()
                ForEach(Page.extras) { page in
                    Toggle(page.title, isOn: binding(page)).font(.system(size: 13)).toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    private func row(_ page: Page) -> some View {
        HStack(spacing: 4) {
            Image(systemName: page.symbol).font(.system(size: 12)).frame(width: 20)
            Text(page.title).font(.system(size: 13)).lineLimit(1)
            Spacer()
            arrow("chevron.up", "\(page.title) を上へ", page, by: -1)
            arrow("chevron.down", "\(page.title) を下へ", page, by: 1)
        }
    }

    private func arrow(_ symbol: String, _ label: String, _ page: Page, by offset: Int) -> some View {
        let result = Page.moved(page, by: offset, in: pages)
        return Button {
            if let result { order = result.map(\.rawValue).joined(separator: ",") }
        } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(result == nil).accessibilityLabel(label)
    }

    private func binding(_ page: Page) -> Binding<Bool> {
        Binding {
            !hidden.split(separator: ",").contains(Substring(page.rawValue))
        } set: { on in
            var off = hidden.split(separator: ",").map(String.init).filter { $0 != page.rawValue }
            if !on { off.append(page.rawValue) }
            hidden = off.joined(separator: ",")
            if !on, model.page == page { model.page = .overview }
            guard page == .menubar else { return }
            if on {
                if !MenuMetric.selected(UserDefaults.standard.string(forKey: MenuMetric.storageKey) ?? MenuMetric.defaultValue).isEmpty {
                    model.status.acquire("menubar")
                }
            } else {
                model.status.release("menubar")
                MenuHider.shared.setEnabled(false)
            }
        }
    }
}
