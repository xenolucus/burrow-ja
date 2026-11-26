import AppKit
import SwiftUI

/// メインウィンドウのサイズ。設定ページで変えると、次回起動時も同じサイズで開く。
enum WindowSize {
    static let widthKey = "window.width"
    static let heightKey = "window.height"
    static let defaultWidth: Double = 1280
    static let defaultHeight: Double = 820
    /// レイアウトの下限。これより小さいと固定幅のカードが収まらないため変えられない。
    static let minWidth: Double = 1080
    static let minHeight: Double = 700
    static let maxWidth: Double = 3840
    static let maxHeight: Double = 2400

    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    /// 保存値を範囲内に収めたサイズ。未保存または不正な値は既定値になる。
    static var saved: NSSize {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: widthKey)
        let height = defaults.double(forKey: heightKey)
        return NSSize(
            width: clamp(width > 0 ? width : defaultWidth, minWidth, maxWidth),
            height: clamp(height > 0 ? height : defaultHeight, minHeight, maxHeight)
        )
    }

    /// 値を保存してから、開いているメインウィンドウに当てる。
    static func save(width: Double, height: Double) -> NSSize {
        let size = NSSize(width: clamp(width, minWidth, maxWidth), height: clamp(height, minHeight, maxHeight))
        UserDefaults.standard.set(Double(size.width), forKey: widthKey)
        UserDefaults.standard.set(Double(size.height), forKey: heightKey)
        NSApp.burrowWindow?.setContentSize(size)
        return size
    }
}

/// 設定ページのウィンドウサイズ欄。
struct WindowSizeCard: View {
    @AppStorage(WindowSize.widthKey) private var width = WindowSize.defaultWidth
    @AppStorage(WindowSize.heightKey) private var height = WindowSize.defaultHeight

    var body: some View {
        GlowCard(glow: .graphite, style: .plain, padding: 22) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ウィンドウサイズ").cardTitle()
                    Text("メインウィンドウの幅と高さ (pt)。次回の起動時にも同じサイズで開きます。下限は \(Int(WindowSize.minWidth)) × \(Int(WindowSize.minHeight))。これより小さいとカードが収まりません。").caption()
                        .frame(maxWidth: 520, alignment: .leading)
                }
                Spacer()
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("幅").font(ThemeType.body)
                        TextField("幅", value: $width, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                    GridRow {
                        Text("高さ").font(ThemeType.body)
                        TextField("高さ", value: $height, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                }
                HStack(spacing: 10) {
                    Button("適用") { applySize() }
                        .buttonStyle(.pill)
                    Button("既定に戻す") {
                        width = WindowSize.defaultWidth
                        height = WindowSize.defaultHeight
                        applySize()
                    }
                    .buttonStyle(.pillSecondary)
                }
            }
        }
    }

    private func applySize() {
        let size = WindowSize.save(width: width, height: height)
        width = Double(size.width)
        height = Double(size.height)
    }
}
