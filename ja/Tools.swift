import AppKit
import IOKit
import SwiftUI

// MARK: - Fans

/// Reads the System Management Controller, which needs no privileges. Writing fan speeds needs root,
/// so it runs in `Burrow --set-fans` started with the administrator password.
enum SMC {
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    /// The kernel's SMCKeyData_t, field for field.
    struct KeyData {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct Limits { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
        struct Info { var size: UInt32 = 0, type: UInt32 = 0; var attributes: UInt8 = 0 }
        var key: UInt32 = 0
        var version = Version()
        var limits = Limits()
        var info = Info()
        var padding: UInt16 = 0
        var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    struct Fan: Equatable { let actual: Double; let minimum: Double; let maximum: Double; var manual = false }

    static func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    static func number(type: UInt32, bytes: [UInt8]) -> Double? {
        switch type {
        case code("flt ") where bytes.count >= 4:
            return Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        case code("fpe2") where bytes.count >= 2:
            return Double(Int(bytes[0]) << 6 | Int(bytes[1]) >> 2)
        case code("ui8 ") where bytes.count >= 1:
            return Double(bytes[0])
        case code("ui16") where bytes.count >= 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case code("ui32") where bytes.count >= 4:
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case code("sp78") where bytes.count >= 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default:
            return nil
        }
    }

    static func name(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(code >> $0 & 0xFF) }, encoding: .ascii) ?? ""
    }

    struct Temperature: Equatable { let place: String; let average: Double; let maximum: Double; let count: Int }

    /// Where a sensor sits, from the first two letters of its key. Apple does not document these;
    /// they follow the names used by open-source monitors.
    static let places: [(String, [String])] = [
        ("CPU", ["Tp", "Te", "TC", "Tc"]), ("GPU", ["Tg", "TG"]), ("メモリ", ["Tm", "TM"]), ("ストレージ", ["TH", "TN"]),
        ("バッテリー", ["TB"]), ("本体の表面", ["Ts", "TS"]), ("吸気（本体に入る空気）", ["Ta", "TA"]), ("Wi-Fi", ["TW"]),
    ]

    static func group(_ readings: [(key: String, celsius: Double)]) -> [Temperature] {
        let valid = readings.filter { $0.celsius > 0 && $0.celsius < 130 }
        return (places.map { $0.0 } + ["その他"]).compactMap { place in
            let values = valid.filter { reading in
                let prefix = String(reading.key.prefix(2))
                let known = places.first { $0.1.contains(prefix) }?.0
                return (known ?? "その他") == place
            }.map { $0.celsius }
            guard let maximum = values.max() else { return nil }
            return Temperature(place: place, average: values.reduce(0, +) / Double(values.count), maximum: maximum, count: values.count)
        }
    }

    static func encode(type: UInt32, _ value: Double) -> [UInt8]? {
        switch type {
        case code("flt "):
            let bits = Float(value).bitPattern
            return [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)]
        case code("ui8 "):
            return [UInt8(max(0, min(255, value)))]
        default:
            return nil
        }
    }

    /// The target for a share of the fan's range; never below its own minimum.
    /// A fan that reports no usable range is left to macOS.
    static func canControl(_ fan: Fan) -> Bool { fan.maximum > fan.minimum && fan.minimum >= 0 }

    static func target(_ fan: Fan, share: Double) -> Double {
        fan.minimum + (fan.maximum - fan.minimum) * max(0, min(1, share))
    }

    private static func call(_ connection: io_connect_t, _ input: inout KeyData) -> KeyData? {
        var output = KeyData(), size = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
        return result == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private static func write(_ connection: io_connect_t, _ key: String, _ value: Double) -> Bool {
        var input = KeyData()
        input.key = code(key)
        input.command = 9
        guard let info = call(connection, &input)?.info, let bytes = encode(type: info.type, value) else { return false }
        input.info.size = info.size
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (index, byte) in bytes.prefix(buffer.count).enumerated() { buffer[index] = byte }
        }
        input.command = 6
        return call(connection, &input) != nil
    }

    private static func read(_ connection: io_connect_t, _ key: String) -> Double? {
        var input = KeyData()
        input.key = code(key)
        input.command = 9
        guard let info = call(connection, &input)?.info else { return nil }
        input.info.size = info.size
        input.command = 5
        guard let output = call(connection, &input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(info.size, 32)))) }
        return number(type: info.type, bytes: bytes)
    }

    private static func withConnection<T>(_ fallback: T, _ body: (io_connect_t) -> T) -> T {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return fallback }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return fallback }
        defer { IOServiceClose(connection) }
        return body(connection)
    }

    /// Every key whose name starts with T, found once by walking the whole key table.
    /// A static let runs its initializer once, even when two readings start together.
    private static let temperatureKeys: [String] = withConnection([]) { connection in
        let count = Int(read(connection, "#KEY") ?? 0)
        return (0..<min(count, 6000)).compactMap { key(connection, at: $0) }.filter { $0.hasPrefix("T") }
    }

    private static func key(_ connection: io_connect_t, at index: Int) -> String? {
        var input = KeyData()
        input.command = 8
        input.data32 = UInt32(index)
        return call(connection, &input).map { name($0.key) }
    }

    static func temperatures() -> [Temperature] {
        let keys = temperatureKeys
        return withConnection([]) { connection in
            group(keys.compactMap { key in read(connection, key).map { (key: key, celsius: $0) } })
        }
    }

    private static func fans(_ connection: io_connect_t) -> [Fan] {
        let count = Int(read(connection, "FNum") ?? 0)
        return (0..<min(count, 4)).compactMap { index in
            read(connection, "F\(index)Ac").map {
                Fan(actual: $0, minimum: read(connection, "F\(index)Mn") ?? 0, maximum: read(connection, "F\(index)Mx") ?? 0,
                    manual: (read(connection, "F\(index)Md") ?? 0) == 1)
            }
        }
    }

    /// Empty on Macs without fans, such as a MacBook Air.
    static func fans() -> [Fan] { withConnection([]) { fans($0) } }

    /// Root only. nil hands the fans back to macOS; a share fixes every fan at that point of its range.
    static func setFans(share: Double?) -> Bool {
        withConnection(false) { connection in
            let list = fans(connection)
            guard !list.isEmpty, share == nil || list.allSatisfy(canControl) else { return false }
            // Some Apple silicon Macs refuse a manual mode until this test flag is set.
            let unlocked = read(connection, "Ftst") != nil
            if unlocked { _ = write(connection, "Ftst", share == nil ? 0 : 1) }
            return list.indices.allSatisfy { index in
                guard let share else { return write(connection, "F\(index)Md", 0) }
                return write(connection, "F\(index)Md", 1) && write(connection, "F\(index)Tg", target(list[index], share: share))
            }
        }
    }

    /// `Burrow --set-fans auto|0.6`, started as root by `FanControl.apply`. Ends the process.
    static func runCommandIfAsked() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--set-fans"), arguments.indices.contains(flag + 1) else { return }
        let share = Double(arguments[flag + 1])
        guard share != nil || arguments[flag + 1] == "auto" else { exit(2) }
        exit(setFans(share: share) ? 0 : 1)
    }
}

enum FanControl {
    /// Asks for the administrator password, then runs this app's own binary as root.
    static func apply(_ share: Double?) -> Bool {
        guard let binary = Bundle.main.executablePath else { return false }
        let command = Remaining.shellQuoted([binary]) + " --set-fans " + (share.map { String($0) } ?? "auto")
        let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(quoted)\" with administrator privileges"]
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

// MARK: - Full-screen covers

private final class CoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// What the monitor check shows, in order.
enum MonitorPattern: CaseIterable {
    case white, black, red, green, blue, cyan, magenta, yellow, gray50, gray25, bars, ramps, steps, nearBlack, nearWhite,
         gamma, contrast, checker, vLines, hLines, text, grid, motion

    var name: String {
        switch self {
        case .white: "白 (255, 255, 255)"
        case .black: "黒 (0, 0, 0)"
        case .red: "赤 (255, 0, 0)"
        case .green: "緑 (0, 255, 0)"
        case .blue: "青 (0, 0, 255)"
        case .cyan: "シアン (0, 255, 255)"
        case .magenta: "マゼンタ (255, 0, 255)"
        case .yellow: "黄 (255, 255, 0)"
        case .gray50: "灰 50%（ムラと光漏れ）"
        case .gray25: "灰 25%（暗い部分のムラ）"
        case .bars: "カラーバー"
        case .gamma: "ガンマ（離れて見て中央の四角が縞に溶ければ 2.2）"
        case .contrast: "コントラスト（白黒の市松）"
        case .checker: "1 ピクセルの市松（シャープさ、拡大の有無）"
        case .vLines: "1 ピクセルの縦線（ちらつき、にじみ）"
        case .hLines: "1 ピクセルの横線（ちらつき、にじみ）"
        case .text: "文字のくっきり具合"
        case .ramps: "グラデーション（段差が見えなければ滑らか）"
        case .steps: "32 段階（隣どうしの区別がつくか）"
        case .nearBlack: "黒の限界（0〜20 のうち見える段まで）"
        case .nearWhite: "白の限界（235〜255 のうち見える段まで）"
        case .grid: "格子（ピントとゆがみ）"
        case .motion: "動きとフレームレート"
        }
    }

    /// 0...1 per channel for the solid colors.
    var rgb: (Double, Double, Double)? {
        switch self {
        case .white: (1, 1, 1)
        case .black: (0, 0, 0)
        case .red: (1, 0, 0)
        case .green: (0, 1, 0)
        case .blue: (0, 0, 1)
        case .cyan: (0, 1, 1)
        case .magenta: (1, 0, 1)
        case .yellow: (1, 1, 0)
        case .gray50: (0.5, 0.5, 0.5)
        case .gray25: (0.25, 0.25, 0.25)
        default: nil
        }
    }
}

/// Frames drawn in the last second, counted from the display's own redraws.
final class FrameMeter {
    private var times: [TimeInterval] = []
    private(set) var count = 0

    func tick(_ time: TimeInterval) -> Int {
        count += 1
        times.append(time)
        times.removeAll { time - $0 > 1 }
        return times.count
    }
}

/// Screen wiping, keyboard cleaning and the monitor check all take over the screen, one at a time.
@MainActor final class Cover: ObservableObject {
    static let shared = Cover()
    enum Mode: Equatable { case wipe, keyboard, monitor(Int) }

    @Published private(set) var mode: Mode?
    @Published var pattern = 0
    @Published private(set) var secondsLeft = 0
    /// Display P3 instead of sRGB: shows how far past sRGB the screen reaches.
    @Published var wide = false
    @Published private(set) var screenInfo = ""
    private var windows: [NSWindow] = []
    private var monitor: Any?
    private var escapes = 0
    private var timer: Task<Void, Never>?

    static let patterns = MonitorPattern.allCases
    static let keyboardSeconds = 60

    func start(_ mode: Mode) {
        stop()
        self.mode = mode
        pattern = 0
        escapes = 0
        let screens: [NSScreen]
        if case .monitor(let index) = mode, NSScreen.screens.indices.contains(index) {
            let screen = NSScreen.screens[index], scale = screen.backingScaleFactor
            screenInfo = "\(screen.localizedName) · \(Int(screen.frame.width * scale))×\(Int(screen.frame.height * scale)) · 最大 \(screen.maximumFramesPerSecond) Hz"
                + (screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 ? " · HDR 対応" : "")
        }
        switch mode {
        case .monitor(let index): screens = NSScreen.screens.indices.contains(index) ? [NSScreen.screens[index]] : []
        case .keyboard: screens = NSScreen.main.map { [$0] } ?? []
        case .wipe: screens = NSScreen.screens
        }
        // A screen unplugged after it was picked: nothing to cover, and the cursor must not stay hidden.
        guard !screens.isEmpty else { self.mode = nil; return }
        for screen in screens {
            let window = CoverWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.contentView = NSHostingView(rootView: CoverView(cover: self))
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate()
        if mode != .keyboard { NSCursor.hide() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            // The keyboard screen keeps its mouse, so its button can end it early.
            guard let self, self.mode != .keyboard else { return event }
            self.handle(event)
            return nil
        }
        if mode == .keyboard {
            KeyboardLock.start()
            secondsLeft = Self.keyboardSeconds
            timer = Task { [weak self] in
                while let self, self.secondsLeft > 0, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self.secondsLeft -= 1
                }
                if !Task.isCancelled { self?.stop() }
            }
        }
    }

    func stop() {
        guard mode != nil else { return }
        timer?.cancel()
        KeyboardLock.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if mode != .keyboard { NSCursor.unhide() }
        mode = nil
    }

    private func handle(_ event: NSEvent) {
        switch mode {
        case .wipe:
            // Two presses, so a cloth leaning on the keyboard does not end it.
            // keyCode raises on a mouse event, so check the type first.
            if event.type == .keyDown, event.keyCode == 53 { escapes += 1 }
            if escapes >= 2 { stop() }
        case .monitor:
            if event.type == .keyDown, event.keyCode == 53 { return stop() }
            if event.type == .keyDown, event.keyCode == 35 { return wide.toggle() }  // P
            let back = event.type == .keyDown && event.keyCode == 123
            pattern = (pattern + (back ? Self.patterns.count - 1 : 1)) % Self.patterns.count
        default:
            break
        }
    }
}

private struct CoverView: View {
    @ObservedObject var cover: Cover

    var body: some View {
        ZStack {
            switch cover.mode {
            case .monitor: pattern(Cover.patterns[cover.pattern])
            default: Color.black
            }
            VStack(spacing: 14) {
                Spacer()
                switch cover.mode {
                case .wipe:
                    Text("画面を拭けます。Esc を2回押すと終わります。").foregroundStyle(.white.opacity(0.35))
                case .keyboard:
                    Text("キーボードを拭けます").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                    Text("キーは入力されません。あと \(cover.secondsLeft) 秒で自動で終わります。").foregroundStyle(.white.opacity(0.7))
                    Button("終了する") { cover.stop() }.buttonStyle(.pill).padding(.top, 8)
                case .monitor:
                    VStack(spacing: 2) {
                        Text("\(cover.pattern + 1)/\(Cover.patterns.count)　\(Cover.patterns[cover.pattern].name)　色空間: \(cover.wide ? "Display P3" : "sRGB")")
                        Text("\(cover.screenInfo)　クリックか → で次へ、← で前へ、P で色空間、Esc で終了")
                    }
                    .font(.system(size: 12)).padding(6).background(.black.opacity(0.6)).foregroundStyle(.white)
                case nil:
                    EmptyView()
                }
                Spacer().frame(height: 40)
            }
            .font(.system(size: 14))
        }
        .ignoresSafeArea()
    }

    private func color(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(cover.wide ? .displayP3 : .sRGB, red: red, green: green, blue: blue)
    }

    /// White, yellow, cyan, green, magenta, red, blue, black.
    private static let bars: [(Double, Double, Double)] = [(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0), (1, 0, 1), (1, 0, 0), (0, 0, 1), (0, 0, 0)]

    /// One row per channel: gray, red, green, blue.
    private var channels: [(Double, Double, Double)] { [(1, 1, 1), (1, 0, 0), (0, 1, 0), (0, 0, 1)] }

    @ViewBuilder private func pattern(_ pattern: MonitorPattern) -> some View {
        if let rgb = pattern.rgb {
            color(rgb.0, rgb.1, rgb.2)
        } else {
            switch pattern {
            case .ramps:
                VStack(spacing: 0) {
                    ForEach(channels.indices, id: \.self) { row in
                        let (red, green, blue) = channels[row]
                        LinearGradient(colors: [color(0, 0, 0), color(red, green, blue)], startPoint: .leading, endPoint: .trailing)
                    }
                }
            case .steps:
                VStack(spacing: 0) {
                    ForEach(channels.indices, id: \.self) { row in
                        let (red, green, blue) = channels[row]
                        HStack(spacing: 0) {
                            ForEach(0..<32, id: \.self) { step in
                                let level = Double(step) / 31
                                color(red * level, green * level, blue * level)
                            }
                        }
                    }
                }
            case .nearBlack, .nearWhite:
                let base = pattern == .nearBlack ? 0 : 235
                ZStack {
                    pattern == .nearBlack ? Color.black : color(1, 1, 1)
                    HStack(spacing: 0) {
                        ForEach(0...20, id: \.self) { step in
                            let level = Double(base + step) / 255
                            ZStack(alignment: .bottom) {
                                color(level, level, level)
                                Text("\(base + step)").font(.system(size: 11)).padding(.bottom, 90)
                                    .foregroundStyle(pattern == .nearBlack ? .white.opacity(0.5) : .black.opacity(0.5))
                            }
                        }
                    }
                    .frame(height: 320)
                }
            case .motion:
                MotionTest()
            case .bars:
                HStack(spacing: 0) {
                    ForEach(Self.bars.indices, id: \.self) { index in
                        let (red, green, blue) = Self.bars[index]
                        color(red, green, blue)
                    }
                }
            case .checker, .vLines, .hLines:
                PixelPattern(pattern: pattern)
            case .gamma:
                ZStack {
                    PixelPattern(pattern: .hLines)
                    // Half the light of white, written in sRGB: matches the stripes only at gamma 2.2.
                    Color(.sRGB, white: 0.7354).frame(width: 320, height: 320)
                }
            case .contrast:
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<4, id: \.self) { column in (row + column).isMultiple(of: 2) ? Color.white : Color.black }
                        }
                    }
                }
            case .text:
                VStack(spacing: 0) {
                    ForEach([Color.white, Color.black], id: \.self) { background in
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach([7, 9, 11, 13, 16, 20, 28], id: \.self) { size in
                                Text("\(size) pt　あいうえお 永 ABCDEFG abcdefg 0123456789 ¥&@#").font(.system(size: CGFloat(size)))
                            }
                        }
                        .foregroundStyle(background == .white ? Color.black : Color.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 60)
                        .background(background)
                    }
                }
            default:
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                    var lines = Path()
                    for x in stride(from: 0, through: size.width, by: 50) { lines.addRect(CGRect(x: x, y: 0, width: 1, height: size.height)) }
                    for y in stride(from: 0, through: size.height, by: 50) { lines.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)) }
                    context.fill(lines, with: .color(.white))
                    context.stroke(Path(ellipseIn: CGRect(x: size.width / 2 - size.height / 3, y: size.height / 6,
                                                          width: size.height * 2 / 3, height: size.height * 2 / 3)),
                                   with: .color(.white), lineWidth: 2)
                }
            }
        }
    }
}

/// Drawn pixel for pixel, so the screen's own scaling cannot blur it.
private struct PixelPattern: View {
    let pattern: MonitorPattern
    @Environment(\.displayScale) private var scale

    static func isOn(_ pattern: MonitorPattern, x: Int, y: Int) -> Bool {
        switch pattern {
        case .checker: (x + y).isMultiple(of: 2)
        case .vLines: x.isMultiple(of: 2)
        default: y.isMultiple(of: 2)
        }
    }

    static func image(_ pattern: MonitorPattern, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for y in 0..<height {
            for x in 0..<width { data[y * width + x] = isOn(pattern, x: x, y: y) ? 255 : 0 }
        }
        return context.makeImage()
    }

    var body: some View {
        GeometryReader { geometry in
            if let image = Self.image(pattern, width: Int(geometry.size.width * scale), height: Int(geometry.size.height * scale)) {
                Image(decorative: image, scale: scale).interpolation(.none)
            }
        }
    }
}

/// Blocks moving at three speeds, a lamp that steps once per frame, and the measured frame rate.
private struct MotionTest: View {
    @State private var meter = FrameMeter()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let fps = meter.tick(time)
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.15)))
                for (row, speed) in [480.0, 960.0, 1920.0].enumerated() {
                    let y = size.height * (0.25 + 0.17 * Double(row))
                    let x = (time * speed).truncatingRemainder(dividingBy: size.width + 120) - 120
                    context.fill(Path(CGRect(x: x, y: y, width: 120, height: 90)), with: .color(.white))
                    context.draw(Text("\(Int(speed)) px/秒").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)),
                                 at: CGPoint(x: 70, y: y - 14))
                }
                // A skipped frame leaves one lamp dark when photographed.
                for lamp in 0..<8 {
                    let lit = meter.count % 8 == lamp
                    context.fill(Path(CGRect(x: size.width / 2 - 160 + Double(lamp) * 40, y: size.height * 0.82, width: 32, height: 32)),
                                 with: .color(lit ? .white : Color(white: 0.3)))
                }
                context.draw(Text("実測 \(fps) fps").font(.system(size: 40, weight: .bold)).foregroundStyle(.white),
                             at: CGPoint(x: size.width / 2, y: size.height * 0.12))
            }
        }
    }
}

// MARK: - Keyboard lock

/// Swallows every key, including brightness and media keys, while the keyboard is being cleaned.
enum KeyboardLock {
    nonisolated(unsafe) private static var tap: CFMachPort?
    nonisolated(unsafe) private static var source: CFRunLoopSource?

    static var allowed: Bool { AXIsProcessTrusted() }

    static func askForPermission() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static func start() {
        guard tap == nil else { return }
        // 14 is NX_SYSDEFINED: the brightness, volume and media keys.
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue) | (1 << 14)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                callback: { _, type, event, _ in
                                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                                        if let tap = KeyboardLock.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                                        return Unmanaged.passUnretained(event)
                                    }
                                    return nil
                                }, userInfo: nil)
        guard let tap else { return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    static func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }
}

// MARK: - Page

struct ToolsPage: View {
    @ObservedObject private var cover = Cover.shared
    /// nil until the first reading, so a Mac with fans never flashes the no-fan text.
    @ViewState private var fans: [SMC.Fan]?
    @ViewState private var screen = 0
    @ViewState private var needsPermission = false
    @ViewState private var fanBusy = false
    @ViewState private var fanFailed = false
    @ViewState private var fanShare = 0.5
    @ViewState private var temperatures: [SMC.Temperature] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                tool("画面を拭く", "sparkles", "すべての画面を黒くして、汚れを見やすくします。Esc を2回押すと終わります。", button: "始める") {
                    cover.start(.wipe)
                }
                tool("キーボードを拭く", "keyboard", "\(Cover.keyboardSeconds) 秒間、キーの入力を止めます。画面のボタンで早めに終えられます。",
                     button: "始める") {
                    if KeyboardLock.allowed { cover.start(.keyboard) } else { needsPermission = true; KeyboardLock.askForPermission() }
                }
                monitorCard
                fanCard
                temperatureCard
            }
            if needsPermission && !KeyboardLock.allowed {
                Text("キーボードを止めるには「システム設定」→「プライバシーとセキュリティ」→「アクセシビリティ」で Burrow JA をオンにしてください。")
                    .font(.system(size: 12)).foregroundStyle(Theme.danger)
            }
        }
        .task {
            while !Task.isCancelled {
                fans = await Task.detached(priority: .utility) { SMC.fans() }.value
                temperatures = await Task.detached(priority: .utility) { SMC.temperatures() }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var temperatureCard: some View {
        GlowCard(glow: .violet, style: .rim, padding: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Label("温度", systemImage: "thermometer.medium").cardTitle()
                if temperatures.isEmpty {
                    Text("温度センサーを読めませんでした。").caption().fixedSize(horizontal: false, vertical: true)
                }
                ForEach(temperatures, id: \.place) { item in
                    HStack {
                        Text(item.place).font(.system(size: 13))
                        Spacer()
                        Text(String(format: "%.1f℃", item.average)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        Text(String(format: "最高 %.0f℃・%d 個", item.maximum, item.count)).caption().fixedSize(horizontal: false, vertical: true).frame(width: 96, alignment: .trailing)
                    }
                }
                Text("Mac に外気温のセンサーはありません。「吸気」が本体に入る空気の温度で、外気にいちばん近い値です。項目の分け方はセンサー名からの推定です。").caption().fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setFans(_ share: Double?) {
        fanBusy = true
        Task {
            fanFailed = !(await Task.detached(priority: .userInitiated) { FanControl.apply(share) }.value)
            fans = await Task.detached(priority: .utility) { SMC.fans() }.value
            fanBusy = false
        }
    }

    private func tool(_ title: String, _ symbol: String, _ detail: String, button: String, action: @escaping () -> Void) -> some View {
        GlowCard(glow: .violet, style: .rim, padding: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol).cardTitle()
                Text(detail).caption().fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(button, action: action).buttonStyle(.pill)
                }
            }
        }
    }

    private var monitorCard: some View {
        GlowCard(glow: .violet, style: .rim, padding: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Label("モニターのチェック", systemImage: "display").cardTitle()
                Text("RGB の各色 100%、カラーバー、グラデーション、黒と白の限界、ガンマ、1 ピクセルの模様、文字、格子、動きとフレームレートの \(MonitorPattern.allCases.count) 種類を順に確かめます。P で sRGB と Display P3 を切り替えます。").caption().fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker("画面", selection: $screen) {
                        ForEach(NSScreen.screens.indices, id: \.self) { Text(NSScreen.screens[$0].localizedName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                    Button("始める") { cover.start(.monitor(screen)) }.buttonStyle(.pill)
                }
            }
        }
    }

    private var fanCard: some View {
        GlowCard(glow: .violet, style: .rim, padding: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Label("ファン", systemImage: "fan").cardTitle()
                if self.fans?.isEmpty == true {
                    Text("このデバイスにはファンが搭載されていません。").caption().fixedSize(horizontal: false, vertical: true)
                }
                let fans = self.fans ?? []
                ForEach(fans.indices, id: \.self) { index in
                    let fan = fans[index]
                    HStack {
                        Text("ファン \(index + 1)").font(.system(size: 13))
                        Spacer()
                        Text("\(Int(fan.actual)) rpm").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        Text("（\(Int(fan.minimum))〜\(Int(fan.maximum))）").caption().fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let first = fans.first, SMC.canControl(first) {
                    HStack(spacing: 10) {
                        Slider(value: $fanShare, in: 0...1, onEditingChanged: { editing in
                            if !editing { setFans(fanShare) }
                        })
                        .disabled(fanBusy).accessibilityLabel("ファンの回転数")
                        Text("\(Int(SMC.target(first, share: fanShare))) rpm").font(.system(size: 13, weight: .medium)).monospacedDigit()
                            .frame(width: 76, alignment: .trailing)
                        Button("自動") { setFans(nil) }.buttonStyle(.pillSecondary).disabled(fanBusy)
                    }
                    Text("スライダーを離すと反映します。ファンが2つあれば、どちらも同じ割合にします。").caption().fixedSize(horizontal: false, vertical: true)
                    Text(fans.contains(where: \.manual) ? "固定中です。温度が上がっても速くなりません。使い終わったら「自動」に戻してください。"
                         : "今は macOS が温度に合わせて決めています。")
                        .font(.system(size: 12)).foregroundStyle(fans.contains(where: \.manual) ? Theme.danger : Theme.secondaryText)
                    Text("変更のたびに管理者パスワードを求めます。最低回転数より遅くはしません。").caption().fixedSize(horizontal: false, vertical: true)
                }
                if fanFailed {
                    Text("変更できませんでした。この Mac では対応していないかもしれません。").font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
            }
        }
    }
}

// MARK: - Trash

/// Mole empties only ~/.Trash. Finder also empties drive and iCloud Drive trash and asks about locked items.
struct TrashPlace: Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    let bytes: Int64
    var id: String { path }

    static func all() -> [TrashPlace] {
        let home = NSHomeDirectory()
        var places = [("Mac のゴミ箱", home + "/.Trash"), ("iCloud Drive のゴミ箱", home + "/Library/Mobile Documents/.Trash")]
        places += ExternalDrives.mounted().map { ("\($0.lastPathComponent) のゴミ箱", $0.path + "/.Trashes/\(getuid())") }
        return places.compactMap { name, path in
            let bytes = FileManager.default.fileExists(atPath: path) ? FolderSize.of(path) : 0
            return bytes > 0 ? TrashPlace(name: name, path: path, bytes: bytes) : nil
        }
    }

    /// Returns false when Finder could not be asked, for example without the Automation permission.
    static func emptyWithFinder() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

struct TrashCard: View {
    @Binding var confirm: ConfirmAction?
    let refresh: Date?
    @ViewState private var places: [TrashPlace] = []
    @ViewState private var failed = false
    @ViewState private var working = false

    var body: some View {
        Group {
            if !places.isEmpty {
                GlowCard(glow: .ember, style: .rim, padding: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ゴミ箱").cardTitle()
                        Text("Mole は Mac のゴミ箱だけを空にします。外付けドライブと iCloud Drive のゴミ箱は Finder で空にします。").caption().fixedSize(horizontal: false, vertical: true)
                        ForEach(places) { place in
                            HStack {
                                Text(place.name).font(.system(size: 13))
                                Spacer()
                                Text(place.bytes.bytesText).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            }
                        }
                        if failed {
                            Text("Finder を操作できませんでした。「システム設定」→「プライバシーとセキュリティ」→「オートメーション」で Burrow JA の Finder をオンにしてください。")
                                .font(.system(size: 12)).foregroundStyle(Theme.danger)
                        }
                        HStack {
                            Spacer()
                            Button("Finder でゴミ箱を空にする") { ask() }.buttonStyle(.pill).disabled(working)
                        }
                    }
                }
            }
        }
        .task(id: refresh) { await reload() }
    }

    private func reload() async {
        places = await Task.detached(priority: .utility) { TrashPlace.all() }.value
    }

    private func ask() {
        let total = places.reduce(Int64(0)) { $0 + $1.bytes }
        confirm = .init(title: "\(total.bytesText) のゴミ箱を空にしますか？",
                        message: "すべてのゴミ箱の項目を完全に削除します。元に戻せません。ロックされた項目は Finder が確認します。",
                        button: "空にする") {
            Task {
                working = true
                failed = !(await Task.detached(priority: .userInitiated) { TrashPlace.emptyWithFinder() }.value)
                working = false
                await reload()
            }
        }
    }
}
