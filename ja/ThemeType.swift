import SwiftUI

/// 文字サイズの基準。追加画面もここの値を使い、直書きの大きさを増やさない。
/// Theme.swift の cardTitle() (15 medium) と caption() (12) と同じ値に揃えている。
enum ThemeType {
    static let display = Font.system(size: 40, weight: .bold)
    static let heading = Font.system(size: 26, weight: .semibold)
    static let title = Font.system(size: 18, weight: .semibold)
    static let cardTitle = Font.system(size: 15, weight: .medium)
    static let lead = Font.system(size: 14, weight: .medium)
    static let leadRegular = Font.system(size: 14)
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .medium)
    static let bodyBold = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 12)
    static let captionStrong = Font.system(size: 12, weight: .medium)
    static let micro = Font.system(size: 11)
    static let microStrong = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 12, design: .monospaced)
}
