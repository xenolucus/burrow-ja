import SwiftUI

/// The live view of a running Mole command: progress, Mole's own log, and native
/// answers to its prompts (admin password, confirmations).
struct RunSheet: View {
    @ObservedObject var session: MoleSession
    @EnvironmentObject private var model: AppModel
    @ViewState private var password = ""
    @ViewState private var showLog = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.system(size: 22, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(statusText)
                        if !session.isFinished { Text("·"); Elapsed(since: session.started) }
                    }
                    .caption()
                    .contentTransition(.opacity)
                }
                Spacer()
                Orb(state: orbState).frame(width: 54, height: 54)
            }

            GlowCard(glow: glowForState, style: .core, padding: 22) {
                if showLog {
                    log
                } else {
                    RunActivity(progress: RunProgress.parse(lines: session.lines, live: session.live),
                                plan: session.plan, glow: glowForState, phase: session.phase)
                }
            }
            .frame(height: showLog ? 420 : 480)
            .animation(Motion.spring, value: showLog)

            prompt
                .transition(.blurFade)

            HStack {
                Button(showLog ? "Hide log" : "Show log") { showLog.toggle() }
                    .buttonStyle(.pillSecondary)
                    .help("Mole's own output, line by line")
                Spacer()
                if session.isFinished {
                    Button("Done") { model.closeSession() }
                        .buttonStyle(.pill)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Stop") { session.cancel() }.buttonStyle(.pillSecondary)
                        .help("Stops Mole the way Ctrl-C would, so Mole cleans up after itself")
                }
            }
        }
        .padding(28)
        .frame(width: 680)
        .background(Theme.background)
        .animation(Motion.spring, value: session.phase)
        .interactiveDismissDisabled(!session.isFinished)
    }

    /// Everything Mole printed, as it printed it.
    private var log: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(session.lines.enumerated()), id: \.offset) { _, line in
                    LogLine(text: line)
                }
                if !session.live.isEmpty, !session.isFinished {
                    LogLine(text: session.live).opacity(0.75)
                }
                if session.lines.isEmpty, session.live.isEmpty {
                    Text("Starting Mole…").caption()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
    }

    @ViewBuilder private var prompt: some View {
        switch session.phase {
        case .needsPassword:
            GlowCard(glow: .violet, style: .rim, padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Mole needs your administrator password for this step", systemImage: "lock.fill").cardTitle()
                    HStack {
                        SecureField("Password", text: $password)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 14).frame(height: 36)
                            .background(Capsule().fill(.black.opacity(0.45)))
                            .focused($passwordFocused)
                            .onSubmit(sendPassword)
                        Button("Continue", action: sendPassword).buttonStyle(.pill)
                    }
                    Text("The password goes straight to macOS sudo and is never stored.").caption()
                }
            }
            .frame(height: 150)
            .onAppear { passwordFocused = true }
        case .needsAnswer(let question):
            GlowCard(glow: .ember, style: .rim, padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(QuickReply.title(for: question)).cardTitle().lineLimit(3)
                    HStack(spacing: 10) {
                        ForEach(QuickReply.options(for: question), id: \.label) { option in
                            Button(option.label) { session.reply(option.keys) }
                                .buttonStyle(option.primary ? .pill : .pillSecondary)
                                .keyboardShortcut(option.primary ? .defaultAction : option.keys == "\u{1B}" ? .cancelAction : nil)
                        }
                    }
                }
            }
            .frame(minHeight: 112)
            .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private func sendPassword() {
        guard !password.isEmpty else { return }
        session.submitPassword(password)
        password = ""
    }

    private var statusText: String {
        switch session.phase {
        case .running: "Working…"
        case .needsPassword: "Waiting for your password"
        case .needsAnswer: "Waiting for you"
        case .finished(let code): code == 0 ? "Finished" : code == 130 || code == 143 ? "Stopped" : "Mole stopped with code \(code)"
        }
    }

    private var orbState: Orb.State {
        switch session.phase {
        case .finished(let code): code == 0 ? .done : .failed
        case .running: .working
        default: .waiting
        }
    }

    private var glowForState: Glow {
        switch orbState {
        case .done: .lime
        case .failed: .ember
        case .waiting: .violet
        case .working: .blue
        }
    }
}

/// Buttons for a prompt Mole is showing, based on the keys it names.
struct QuickReply {
    let label: String
    let keys: String
    var primary = false

    static func options(for prompt: String) -> [QuickReply] {
        let p = prompt.lowercased()
        var options: [QuickReply] = []
        if p.contains("enter") {
            // "Remove 2 apps, 90.5MB  Enter confirm": the button says what it does.
            let first = title(for: prompt).components(separatedBy: " ").first ?? ""
            let verb = ["Remove", "Uninstall", "Slim", "Clean", "Delete", "Purge", "Optimize"].contains(first) ? first
                : p.contains("confirm") ? "Confirm" : p.contains("continue") ? "Continue" : "Enter"
            options.append(.init(label: verb, keys: "\r", primary: true))
        }
        if p.contains("space") {
            options.append(.init(label: p.contains("skip") ? "Skip" : "Space", keys: " "))
        }
        if p.contains("y/n") {
            options.append(.init(label: "Yes", keys: "y\r", primary: options.isEmpty))
            options.append(.init(label: "No", keys: "n\r"))
        }
        if p.contains("esc") || p.contains("cancel") || p.contains("quit") {
            options.append(.init(label: "Cancel", keys: "\u{1B}"))
        }
        if options.isEmpty {
            options = [.init(label: "Enter", keys: "\r", primary: true), .init(label: "Cancel", keys: "\u{1B}")]
        }
        return options
    }

    /// The question without Mole's key hints: "➤ Remove 2 apps, 90.5MB  Enter confirm, ESC cancel:" → "Remove 2 apps, 90.5MB?"
    static func title(for prompt: String) -> String {
        var s = prompt.trimmingCharacters(in: CharacterSet(charactersIn: "➤→◎⊙ "))
        if let hint = s.range(of: #"\s+(Enter|ESC|Space|Q)\s+(confirm|cancel|continue|skip)|\s*\[?[yY]/[nN]\]?"#, options: .regularExpression) {
            s = String(s[..<hint.lowerBound])
        } else {
            return s
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " :,"))
            .replacingOccurrences(of: #"([0-9])(TB|GB|MB|KB)\b"#, with: "$1 $2", options: .regularExpression)
        // "System caches need sudo." stays a statement.
        return s.hasSuffix("?") || s.hasSuffix(".") ? s : s + "?"
    }
}

/// A real run drawn as progress, not a terminal: how much is freed, what Mole is doing now,
/// and each step as it finishes.
private struct RunActivity: View {
    let progress: RunProgress
    let plan: Int64?
    let glow: Glow
    let phase: MoleSession.Phase

    private var done: [RunProgress.Step] { progress.steps.filter { $0.kind == .done } }
    /// Mole's own total from its question, else the sizes it listed, else the total the user confirmed.
    private var planTotal: Int64? {
        let listed = progress.planned.compactMap(\.bytes).reduce(0, +)
        return progress.promptBytes ?? (listed > 0 ? listed : plan)
    }
    private var showsBytes: Bool { planTotal != nil || progress.freed > 0 }
    /// Until something is freed the figure is what the run is about to free, not a zero.
    private var headline: (caption: String, value: Int64) {
        if progress.dryRun { return ("Would free", progress.freed > 0 ? progress.freed : planTotal ?? 0) }
        if idle { return ("Nothing removed", 0) }
        // Only for a list of apps: Clean frees from its first step, so its total would drop at once.
        if progress.freed == 0, !finished, !progress.planned.isEmpty, let planTotal { return ("To free", planTotal) }
        return (finished ? "Freed" : "Freed so far", progress.freed)
    }
    private var finished: Bool { if case .finished = phase { return true }; return false }
    private var working: Bool { phase == .running }
    /// Mole exited cleanly but did nothing, for example after its own confirmation was declined.
    private var idle: Bool { phase == .finished(0) && progress.steps.isEmpty && progress.freed == 0 }
    /// Listed items Mole has not reported done yet.
    private var upcoming: [RunProgress.Step] {
        progress.planned.filter { item in !progress.steps.contains { $0.name == item.name } }
    }

    /// Mole's spinner text while it works; otherwise what the run is waiting for, or how it ended.
    private var activity: String {
        switch phase {
        case .running:
            progress.now ?? progress.steps.last?.section.map { "Working on \($0.lowercased())" }
                ?? (progress.steps.isEmpty ? "Starting Mole" : "Working")
        case .needsPassword: "Waiting for your password"
        case .needsAnswer: progress.review.isEmpty ? "Waiting for your answer" : "Check what Mole will remove, then confirm"
        case .finished(let code) where code == 0 && progress.dryRun: "Preview only · nothing was removed"
        case .finished(let code) where code == 0:
            idle ? "Nothing was changed"
                : showsBytes ? "Freed \(progress.freed.bytesText) · \(count(done.count))" : "\(count(done.count)) done"
        case .finished(let code): code == 130 || code == 143 ? "Stopped" : "Mole stopped early"
        }
    }

    /// The mark beside the status line when nothing is moving.
    private var statusSymbol: String? {
        switch phase {
        case .running: nil
        case .needsPassword: "lock.fill"
        case .needsAnswer: "questionmark"
        case .finished(let code) where code == 0: progress.dryRun ? "eye" : idle ? "minus" : "checkmark"
        case .finished: "exclamationmark"
        }
    }

    /// Apps for a run over apps (slim, uninstall), steps otherwise.
    private func count(_ n: Int) -> String {
        "\(n) \(progress.planned.isEmpty ? "step" : "app")\(n == 1 ? "" : "s")"
    }

    /// Freed against the plan; else items of the "[2/5]" counter. Full once Mole is done.
    private var fraction: Double? {
        if phase == .finished(0) { return idle ? 0 : 1 }
        // Uninstall frees nothing until each app is gone, so its "[2/5]" counter says more than the bytes.
        if let plan = planTotal, plan > 0, progress.freed > 0 || progress.position == nil { return min(Double(progress.freed) / Double(plan), 1) }
        if let pos = progress.position, pos.of > 0 { return Double(pos.at - (progress.positionDone ? 0 : 1)) / Double(pos.of) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(showsBytes ? headline.caption : "Steps done").caption()
                        .contentTransition(.opacity)
                    CountingValue(value: Double(showsBytes ? headline.value : Int64(done.count)), bytes: showsBytes)
                        .animation(Motion.reduced ? nil : .smooth(duration: 0.6), value: headline.value)
                        // A new caption is a new figure, not the old one counting down.
                        .id(headline.caption)
                        .transition(.blurFade)
                        .scaleEffect(finished && !Motion.reduced ? 1.04 : 1, anchor: .bottomLeading)
                        .animation(Motion.spring, value: finished)
                }
                .animation(Motion.reduced ? nil : Motion.spring, value: headline.caption)
                Spacer()
                if let pos = progress.position, pos.of > 1, !finished {
                    VStack(alignment: .trailing, spacing: 12) {
                        Text("Item").caption()
                        DotMatrixText(text: "\(pos.at)/\(pos.of)", dot: 3.5, color: .white.opacity(0.8))
                    }
                }
            }
            if let fraction {
                DotMeter(value: fraction, count: 72, color: glow.color)
            }
            HStack(spacing: 12) {
                Group {
                    if working {
                        PulseDot(color: glow.color)
                    } else if let symbol = statusSymbol {
                        Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(glow.color)
                    }
                }
                .frame(width: 18, height: 18)
                Text(activity)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .shimmer(working)
                    .id(activity)
                    .transition(.blurFade)
            }
            .animation(Motion.quick, value: activity)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Color.clear.frame(height: 4).id("top")
                        // Before the go-ahead (and in a preview): every file Mole would remove, by app.
                        ForEach(progress.review) { file in
                            if let app = file.section, file.id == 0 || progress.review[file.id - 1].section != app {
                                SectionTitle(app, bytes: progress.planned.first { $0.name == app }?.bytes, first: file.id == 0)
                            }
                            StepRow(step: file, upcoming: true, review: true).id("review-\(file.id)").transition(.blurFade)
                        }
                        ForEach(progress.review.isEmpty ? progress.steps : []) { step in
                            if let section = step.section, step.id == 0 || progress.steps[step.id - 1].section != section {
                                SectionTitle(section, first: step.id == 0)
                            }
                            StepRow(step: step, tint: glow.color).id(step.id).transition(.blurFade)
                        }
                        ForEach(progress.review.isEmpty ? upcoming : []) { item in
                            // After a run, what is still listed was left alone.
                            StepRow(step: finished ? .init(id: item.id, kind: item.kind, section: nil, name: item.name, detail: "Kept", bytes: item.bytes) : item,
                                    upcoming: true, current: working && (progress.now == item.name || progress.now?.hasSuffix(" " + item.name) == true),
                                    tint: glow.color)
                                .id("planned-\(item.id)")
                        }
                        // Room under the last row, so following it keeps it clear of the fade.
                        Color.clear.frame(height: 28).id("end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(Motion.spring, value: progress.steps.count)
                }
                .scrollIndicators(finished ? .automatic : .never)
                // Rows that run past either edge fade out instead of being cut.
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                             .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onChange(of: progress.review.isEmpty) {
                    // From the files to confirm to the apps being removed: start at the top again.
                    withAnimation(Motion.spring) { proxy.scrollTo("top", anchor: .top) }
                }
                .onChange(of: progress.steps.count) {
                    // Follow the newest finished step; with a planned list, keep the current item in view.
                    guard progress.review.isEmpty, let last = progress.steps.last else { return }
                    withAnimation(Motion.spring) {
                        if upcoming.isEmpty { proxy.scrollTo("end", anchor: .bottom) } else { proxy.scrollTo(last.id, anchor: .center) }
                    }
                }
            }
        }
    }
}

/// A group heading in the run's list: a Clean section, or an app and its size.
private struct SectionTitle: View {
    let text: String
    var bytes: Int64?
    let first: Bool

    init(_ text: String, bytes: Int64? = nil, first: Bool) {
        (self.text, self.bytes, self.first) = (text, bytes, first)
    }

    var body: some View {
        HStack {
            Text(text).textCase(.uppercase)
            Spacer()
            if let bytes { Text(bytes.bytesText).monospacedDigit() }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.tertiaryText)
        .padding(.top, first ? 0 : 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The freed figure (or the step count), counting up to each new value instead of jumping.
private struct CountingValue: View, Animatable {
    var value: Double
    let bytes: Bool
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        if bytes {
            let m = Int64(value).metric
            MetricValue(value: m.value, unit: m.unit, dot: 5, live: true)
        } else {
            MetricValue(value: "\(Int(value.rounded()))", dot: 5, live: true)
        }
    }
}

private struct StepRow: View {
    let step: RunProgress.Step
    /// Listed by Mole but not done yet.
    var upcoming = false
    /// The item Mole is working on now.
    var current = false
    /// A file Mole lists for its confirmation: information, not something to tick.
    var review = false
    var tint: Color = Theme.accent
    @ViewState private var landed = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if current {
                    PulseDot(color: tint)
                } else if review {
                    Image(systemName: step.kind == .note ? "lock" : "doc")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                } else {
                    switch step.kind {
                    case .done: CheckDot(on: landed && !upcoming)
                    case .note where upcoming: CheckDot(on: false)
                    case .note: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Glow.ember.color)
                    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
                    }
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(review ? Theme.secondaryText : upcoming && !current ? Theme.tertiaryText : .white)
                    .shimmer(current)
                if !detail.isEmpty { Text(detail).caption().lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let bytes = step.bytes {
                Text(bytes.bytesText).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .opacity(review ? 0.75 : upcoming ? 0.4 : 1)
            }
        }
        .animation(Motion.quick, value: current)
        // The check pops in once the row is on screen.
        .onAppear { landed = true }
        .accessibilityElement(children: .combine)
        .accessibilityValue(review ? "Will be removed" : upcoming ? (current ? "In progress" : "Waiting")
            : step.kind == .done ? "Done" : step.kind == .failed ? "Failed" : "")
    }

    /// The detail without the size shown on the right ("12 items, 1.2GB" → "12 items").
    private var detail: String {
        guard step.bytes != nil else { return step.detail }
        return step.detail.components(separatedBy: ", ").filter { ByteSize.first(in: $0) == nil }.joined(separator: ", ")
    }
}

private struct LogLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(icon).foregroundStyle(iconColor).frame(width: 12)
            Text(body(of: text))
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(text.hasPrefix("➤") ? .white : Theme.secondaryText)
                .fontWeight(text.hasPrefix("➤") ? .semibold : .regular)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var icon: String {
        guard let f = text.first, "→✓✗◎⊙➤⚙".contains(f) else { return "" }
        return String(f)
    }

    private var iconColor: Color {
        switch text.first {
        case "✓": Theme.accent
        case "✗": Theme.danger
        case "→": .white.opacity(0.7)
        default: Theme.tertiaryText
        }
    }

    private func body(of s: String) -> String {
        icon.isEmpty ? s : String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
}

/// A breathing orb that shows the state of the run.
struct Orb: View {
    enum State { case working, waiting, done, failed }
    let state: State
    @ViewState private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).blur(radius: 12).scaleEffect(pulse ? 1.15 : 0.85)
            Circle().fill(RadialGradient(colors: [.white.opacity(0.9), color, color.opacity(0.3)],
                                         center: .init(x: 0.35, y: 0.3), startRadius: 1, endRadius: 30))
                .overlay(Circle().strokeBorder(.white.opacity(0.4)))
            if state == .done { Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(.black) }
            if state == .failed { Image(systemName: "exclamationmark").font(.system(size: 18, weight: .bold)).foregroundStyle(.black) }
        }
        .animation(Motion.spring, value: state)
        .onAppear {
            guard !Motion.reduced else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
        // A finished run stops breathing, so the open sheet costs nothing while it waits for Done.
        .onChange(of: state) { _, state in
            if state == .done || state == .failed { withAnimation(.easeOut(duration: 0.4)) { pulse = false } }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch state {
        case .working: "Working"
        case .waiting: "Waiting for you"
        case .done: "Finished"
        case .failed: "Stopped"
        }
    }

    private var color: Color {
        switch state {
        case .working: Glow.blue.color
        case .waiting: Glow.violet.color
        case .done: Theme.accent
        case .failed: Theme.danger
        }
    }
}
