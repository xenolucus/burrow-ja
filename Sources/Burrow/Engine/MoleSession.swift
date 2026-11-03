import Foundation
import Darwin

/// Runs one Mole command inside a pseudo-terminal, so Mole keeps its own prompts,
/// sudo handling and safety checks, while the app answers those prompts natively.
@MainActor
final class MoleSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case running
        case needsPassword
        case needsAnswer(String)
        case finished(Int32)
    }

    /// Keys sent automatically when a prompt the UI already decided on appears.
    struct Responder {
        let match: (String) -> Bool
        let keys: [String]

        static func when(_ needle: String, send keys: String...) -> Self {
            .init(match: { $0.localizedCaseInsensitiveContains(needle) }, keys: keys)
        }

        /// Selects rows by name in Mole's searchable multi-select menu, then submits it.
        static func selectInMenu(titled title: String, names: [String]) -> Self {
            var keys: [String] = []
            for name in names {
                keys += ["/", name, "\r", " ", "/", "\u{15}", "\r"]
            }
            keys.append("\r")
            return .init(match: { $0.localizedCaseInsensitiveContains(title) }, keys: keys)
        }
    }

    let id = UUID()
    let title: String
    let args: [String]
    /// What the run should free, from the scan the user confirmed; drives the sheet's meter.
    let plan: Int64?
    @Published private(set) var lines: [String] = []
    @Published private(set) var live = ""
    @Published private(set) var phase: Phase = .running

    private var responders: [Responder]
    private var masterFD: Int32 = -1
    private var pid: pid_t = 0
    private var pending = ""
    private var undecoded = Data()
    private var idleTask: Task<Void, Never>?
    private var typing = false
    /// The prompt last answered; it is not asked again until Mole prints a new line.
    private var answeredPrompt = ""
    let started = Date()
    /// False for a replayed transcript, which quitting cannot interrupt.
    private(set) var runsMole = true

    init(title: String, args: [String], plan: Int64? = nil, responders: [Responder] = []) {
        self.title = title
        self.args = args
        self.plan = plan
        self.responders = responders
    }

    var isFinished: Bool { if case .finished = phase { return true }; return false }
    var exitCode: Int32? { if case .finished(let c) = phase { return c }; return nil }

    func start() {
        let exe = Mole.executable
        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = Mole.environment(tty: true).map { strdup("\($0)=\($1)") } + [nil]
        let home = strdup(FileManager.default.homeDirectoryForCurrentUser.path)
        defer { (argv + envp + [home]).forEach { free($0) } }

        var size = winsize(ws_row: 50, ws_col: 140, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        var unblocked: sigset_t = 0
        let child = forkpty(&master, nil, nil, &size)
        if child == 0 {
            // Child: only async-signal-safe calls until exec. Ignored signals and the signal mask
            // survive exec, and bash cannot trap a signal that was ignored when it started, so
            // Mole gets clean defaults: Stop (SIGINT) then runs Mole's own cleanup traps.
            // Written out one by one: no allocation between fork and exec.
            _ = signal(SIGINT, SIG_DFL)
            _ = signal(SIGTERM, SIG_DFL)
            _ = signal(SIGHUP, SIG_DFL)
            _ = signal(SIGQUIT, SIG_DFL)
            _ = signal(SIGPIPE, SIG_DFL)
            _ = sigprocmask(SIG_SETMASK, &unblocked, nil)
            _ = chdir(home)
            execve(exe, argv, envp)
            _exit(127)
        }
        guard child > 0 else { phase = .finished(-1); return }
        pid = child
        Mole.track(pid: child)
        masterFD = master
        readLoop(fd: master)
        waitLoop(pid: child)
    }

    /// Plays a recorded run instead of starting Mole: for review screenshots and the demo tour.
    /// Each line of the transcript arrives `pace` seconds after the one before; a literal `\r`
    /// in it is a carriage return.
    func replay(_ transcript: String, pace: Double = 0.45) {
        runsMole = false
        Task { [weak self] in
            for line in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
                try? await Task.sleep(for: .seconds(pace))
                // "@hold" stops the replay where it is, so a snapshot can show a run mid-way.
                if line == "@hold" { return }
                // A line ending in a literal \r stays open, like a spinner frame.
                let raw = line.replacingOccurrences(of: "\\r", with: "\r")
                self?.ingest(Data((raw.hasSuffix("\r") ? raw : raw + "\n").utf8))
            }
            try? await Task.sleep(for: .seconds(pace))
            guard let self else { return }
            if !self.pending.isEmpty { self.commit(self.pending); self.pending = "" }
            self.live = ""
            self.phase = .finished(0)
        }
    }

    /// Answers the current prompt.
    func reply(_ text: String) {
        answeredPrompt = live
        phase = .running
        write(text)
    }

    func submitPassword(_ password: String) { reply(password + "\r") }

    /// Asks Mole to stop the way Ctrl-C would, then insists if it is still running.
    func cancel() {
        guard pid > 0, !isFinished else { return }
        write("\u{1B}")
        Mole.signalTree(pid, SIGINT)
        for (delay, sig) in [(1.5, SIGTERM), (4.0, SIGKILL)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isFinished else { return }
                Mole.signalTree(self.pid, sig)
            }
        }
    }

    private func write(_ text: String) {
        guard masterFD >= 0, !isFinished else { return }
        var bytes = Array(text.utf8)
        _ = bytes.withUnsafeMutableBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
    }

    /// Menus drain queued input after some keys, so each key waits for the redraw.
    private func type(_ keys: [String]) {
        typing = true
        Task { [weak self] in
            for key in keys {
                try? await Task.sleep(for: .milliseconds(350))
                self?.write(key)
            }
            try? await Task.sleep(for: .milliseconds(400))
            self?.typing = false
        }
    }

    // MARK: - IO

    private func readLoop(fd: Int32) {
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                let chunk = Data(buf[0..<n])
                DispatchQueue.main.async { self?.ingest(chunk) }
            }
            // The reader owns the descriptor: closing it here can never race a read.
            DispatchQueue.main.sync { if self?.masterFD == fd { self?.masterFD = -1 } }
            close(fd)
        }
    }

    private func waitLoop(pid: pid_t) {
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            Mole.untrack(pid: pid)
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self else { return }
                if !self.pending.isEmpty { self.commit(self.pending); self.pending = "" }
                self.idleTask?.cancel()
                self.live = ""
                self.phase = .finished(code)
            }
        }
    }

    private func ingest(_ chunk: Data) {
        undecoded.append(chunk)
        let cut = Self.completeUTF8Length(undecoded)
        let text = String(decoding: undecoded.prefix(cut), as: UTF8.self)
        undecoded = Data(undecoded.dropFirst(cut))
        // A terminal ends lines with "\r\n", one Character in Swift that never equals "\n".
        // Normalising after appending also joins a "\r" and "\n" split across two reads.
        pending = (pending + text).replacingOccurrences(of: "\r\n", with: "\n")
        while let nl = pending.firstIndex(of: "\n") {
            commit(String(pending[..<nl]))
            pending = String(pending[pending.index(after: nl)...])
        }
        live = TerminalText.visible(pending)
        if !typing { autoRespond() }
        scheduleIdleCheck()
    }

    private func commit(_ raw: String) {
        let line = TerminalText.visible(raw)
        // Spinner frames (braille dots) are progress noise, not log lines.
        guard !line.isEmpty, !(0x2800...0x28FF).contains(line.unicodeScalars.first!.value) else { return }
        answeredPrompt = ""
        if lines.last != line { lines.append(line) }
        if lines.count > 4000 { lines.removeFirst(lines.count - 4000) }
    }

    /// Length of the longest prefix that ends on a complete UTF-8 character.
    nonisolated static func completeUTF8Length(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(4))
        var i = bytes.count - 1
        while i >= 0 {
            let b = bytes[i]
            if b & 0x80 == 0 { return data.count }
            if b & 0xC0 == 0xC0 {
                let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2
                return bytes.count - i >= need ? data.count : data.count - (bytes.count - i)
            }
            i -= 1
        }
        return data.count
    }

    // MARK: - Prompts

    private func autoRespond() {
        let screen = (lines.suffix(6) + [live]).joined(separator: "\n")
        if let i = responders.firstIndex(where: { $0.match(screen) }) {
            let r = responders.remove(at: i)
            type(r.keys)
        }
    }

    /// A line that waits for input with no automatic answer becomes a question for the user.
    private func scheduleIdleCheck() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled, !self.typing, self.phase == .running else { return }
            let text = self.live
            guard !text.isEmpty, text != self.answeredPrompt else { return }
            let lower = text.lowercased()
            if lower.contains("password") {
                self.phase = .needsPassword
            } else if text.hasSuffix(":") || text.hasSuffix("?") || lower.contains("enter")
                        || lower.contains("esc") || lower.contains("y/n") {
                self.phase = .needsAnswer(text)
            }
        }
    }
}
