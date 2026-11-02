import Foundation
import UIKit
import SwiftUI
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH

enum SessionKind { case ssh, sftp }

/// One live SSH shell. Owns the SwiftTerm view so the scrollback survives navigation.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, TerminalViewDelegate, UIGestureRecognizerDelegate {
    enum Phase { case connecting, live, ended }

    let id = uid("ssh")
    let host: Host
    private unowned let store: AppStore

    @Published var title: String
    @Published var phase: Phase = .connecting
    @Published var endMessage: String?
    @Published var stats: RemoteStats?
    @Published var zoom = 0
    /// Sticky modifiers toggled from the on-screen key bar.
    @Published var ctrlActive = false
    @Published var altActive = false
    var onShowSnippets: (() -> Void)?

    let terminalView: TerminalView

    private var client: SSHClient?
    private var runTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var inputCont: AsyncStream<ByteBuffer>.Continuation?
    private var writer: TTYStdinWriter?
    private var started = false
    private var userClosed = false
    private var cols = 80
    private var rows = 24
    private var attempt = 0

    init(host: Host, title: String, store: AppStore) {
        self.host = host
        self.title = title
        self.store = store
        self.terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        super.init()
        terminalView.terminalDelegate = self
        terminalView.inputAccessoryView = KeyBarView(session: self)
        installWheelScroll()
        applySettings()
    }

    // MARK: Appearance

    var fontSize: Int { min(32, max(8, store.settings.fontSize + zoom)) }

    func applySettings() {
        let s = store.settings
        terminalView.font = Self.makeFont(s.fontFamily, size: CGFloat(fontSize))
        applyTheme()
        let style: CursorStyle
        switch (s.cursorStyle, s.cursorBlink) {
        case (.block, true): style = .blinkBlock
        case (.block, false): style = .steadyBlock
        case (.underline, true): style = .blinkUnderline
        case (.underline, false): style = .steadyUnderline
        case (.bar, true): style = .blinkBar
        case (.bar, false): style = .steadyBar
        }
        terminalView.getTerminal().setCursorStyle(style)
        terminalView.getTerminal().changeHistorySize(s.scrollback)
    }

    func applyTheme() {
        let c = TerminalColors.forTheme(store.resolvedTheme)
        func ui(_ hex: UInt32, _ a: CGFloat = 1) -> UIColor { UIColor(hex: hex, alpha: a) }
        func term(_ hex: UInt32) -> SwiftTerm.Color {
            SwiftTerm.Color(
                red: UInt16(((hex >> 16) & 0xFF) * 257),
                green: UInt16(((hex >> 8) & 0xFF) * 257),
                blue: UInt16((hex & 0xFF) * 257)
            )
        }
        terminalView.installColors(c.ansi.map(term))
        terminalView.nativeBackgroundColor = ui(c.background)
        terminalView.nativeForegroundColor = ui(c.foreground)
        terminalView.caretColor = ui(c.cursor)
        terminalView.selectedTextBackgroundColor = ui(c.selection, c.selectionAlpha)
        terminalView.backgroundColor = ui(c.background)
        terminalView.indicatorStyle = store.resolvedTheme == .light ? .black : .white
        terminalView.overrideUserInterfaceStyle = store.resolvedTheme == .light ? .light : .dark
    }

    static func makeFont(_ family: TerminalFont, size: CGFloat) -> UIFont {
        switch family {
        case .sfMono: return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .menlo: return UIFont(name: "Menlo-Regular", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .courier: return UIFont(name: "CourierNewPSMT", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    func changeZoom(_ delta: Int) {
        let next = store.settings.fontSize + zoom + delta
        guard next >= 8 && next <= 32 else { return }
        zoom += delta
        terminalView.font = Self.makeFont(store.settings.fontFamily, size: CGFloat(fontSize))
    }

    func clearScreen() {
        // Clear screen + scrollback, then ask the shell to redraw its prompt.
        terminalView.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
        sendText("\u{0c}")
    }

    func focus() { _ = terminalView.becomeFirstResponder() }
    func blur() { _ = terminalView.resignFirstResponder() }

    // MARK: Connection lifecycle

    func startIfNeeded() {
        guard !started else { return }
        started = true
        connect()
    }

    func reconnect() {
        runTask?.cancel()
        statsTask?.cancel()
        let old = client
        client = nil
        Task { try? await old?.close() }
        userClosed = false
        attempt += 1
        terminalView.feed(text: "\u{1b}c")
        connect()
    }

    private func connect() {
        phase = .connecting
        endMessage = nil
        stats = nil
        let myAttempt = attempt
        runTask = Task { [weak self] in
            await self?.run(attempt: myAttempt)
        }
    }

    private func run(attempt myAttempt: Int) async {
        do {
            let client = try await SSHFactory.connect(host: host, store: store)
            if Task.isCancelled || myAttempt != attempt {
                try? await client.close()
                return
            }
            self.client = client
            client.onDisconnect { [weak self] in
                Task { @MainActor in self?.finish(attempt: myAttempt, error: nil) }
            }
            store.touchLastConnected(host.id)

            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )

            var continuation: AsyncStream<ByteBuffer>.Continuation!
            let input = AsyncStream<ByteBuffer>(bufferingPolicy: .unbounded) { continuation = $0 }
            self.inputCont = continuation

            try await client.withPTY(request) { inbound, outbound in
                self.writer = outbound
                self.phase = .live
                self.startStats()
                let pump = Task {
                    for await chunk in input {
                        try? await outbound.write(chunk)
                    }
                }
                defer { pump.cancel() }
                for try await output in inbound {
                    switch output {
                    case .stdout(let buf), .stderr(let buf):
                        let bytes = Array(buf.readableBytesView)
                        self.terminalView.feed(byteArray: bytes[...])
                    }
                }
            }
            finish(attempt: myAttempt, error: nil)
        } catch {
            finish(attempt: myAttempt, error: error)
        }
    }

    private func finish(attempt myAttempt: Int, error: Error?) {
        guard myAttempt == attempt, phase != .ended else { return }
        statsTask?.cancel()
        stats = nil
        writer = nil
        inputCont?.finish()
        inputCont = nil
        if userClosed {
            phase = .ended
            return
        }
        if let error {
            let message = (error as? AppError)?.message ?? SSHFactory.describe(error, host: host, store: store)
            endMessage = message
            terminalView.feed(text: "\r\n\u{1b}[31m\(store.t("termStartError", ["error": message]))\u{1b}[0m\r\n")
        }
        phase = .ended
    }

    func close() {
        userClosed = true
        runTask?.cancel()
        statsTask?.cancel()
        inputCont?.finish()
        let c = client
        client = nil
        phase = .ended
        Task { try? await c?.close() }
    }

    // MARK: Input

    func sendText(_ text: String) {
        sendBytes(Array(text.utf8))
    }

    func sendBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        inputCont?.yield(ByteBuffer(bytes: bytes))
    }

    // MARK: Wheel scrolling for full-screen apps (opencode, claude, vim, less, htop...)

    /// True while the running program wants the wheel: it enabled mouse tracking or uses the alternate screen.
    /// In a plain shell the native scroll view scrolls the scrollback and this gesture stays out of the way.
    var wantsWheelScroll: Bool {
        let t = terminalView.getTerminal()
        return t.mouseMode != .off || t.isCurrentBufferAlternate
    }

    private var scrollAccum: CGFloat = 0
    private var inertiaTimer: Timer?
    private var inertiaVelocity: CGFloat = 0

    private func installWheelScroll() {
        let pan = TerminalScrollPan(target: self, action: #selector(handleScrollPan(_:)))
        pan.session = self
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        terminalView.addGestureRecognizer(pan)
    }

    private var wheelStep: CGFloat { max(12, terminalView.font.lineHeight * 1.4) }

    func stopInertia() {
        inertiaTimer?.invalidate()
        inertiaTimer = nil
    }

    private func emitWheel(_ delta: CGFloat) {
        scrollAccum += delta
        let step = wheelStep
        while abs(scrollAccum) >= step {
            // Finger moving down = content moving down = wheel up.
            sendWheel(up: scrollAccum > 0)
            scrollAccum += scrollAccum > 0 ? -step : step
        }
    }

    private func sendWheel(up: Bool) {
        let t = terminalView.getTerminal()
        if t.mouseMode != .off {
            let flags = t.encodeButton(button: up ? 4 : 5, release: false, shift: false, meta: false, control: false)
            t.sendEvent(buttonFlags: flags, x: max(0, t.cols / 2), y: max(0, t.rows / 2))
        } else if t.isCurrentBufferAlternate {
            sendKey(up ? .up : .down)
        }
    }

    @objc private func handleScrollPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            stopInertia()
            scrollAccum = 0
            g.setTranslation(.zero, in: terminalView)
        case .changed:
            let dy = g.translation(in: terminalView).y
            g.setTranslation(.zero, in: terminalView)
            emitWheel(dy)
        case .ended:
            inertiaVelocity = g.velocity(in: terminalView).y
            guard abs(inertiaVelocity) > 120 else { return }
            inertiaTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.inertiaVelocity *= 0.94
                if abs(self.inertiaVelocity) < 40 || !self.wantsWheelScroll {
                    self.stopInertia()
                    return
                }
                self.emitWheel(self.inertiaVelocity / 60.0)
            }
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, wantsWheelScroll else { return false }
        let v = pan.velocity(in: terminalView)
        return abs(v.y) >= abs(v.x)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: Key bar support

    func toggleCtrl() { ctrlActive.toggle() }
    func toggleAlt() { altActive.toggle() }

    /// Applies the sticky Ctrl / Alt modifiers to typed input (single characters only).
    func applyModifiers(_ bytes: [UInt8]) -> [UInt8] {
        guard ctrlActive || altActive, !bytes.isEmpty else { return bytes }
        var out = bytes
        if ctrlActive, out.count == 1 {
            let b = out[0]
            if b >= 0x61 && b <= 0x7A { out = [b - 0x60] }          // a-z
            else if b >= 0x40 && b <= 0x5F { out = [b - 0x40] }      // @ A-Z [ \ ] ^ _
            else if b == 0x20 { out = [0] }                          // Ctrl+Space
            else if b == 0x3F { out = [0x7F] }                       // Ctrl+?
            ctrlActive = false
        }
        if altActive {
            out = [0x1B] + out
            altActive = false
        }
        return out
    }

    /// Text typed from the key bar (symbols): honours the sticky modifiers.
    func sendTyped(_ text: String) {
        sendBytes(applyModifiers(Array(text.utf8)))
    }

    enum NavKey { case up, down, left, right, home, end, pageUp, pageDown, escape, tab }

    func sendKey(_ key: NavKey) {
        let app = terminalView.getTerminal().applicationCursor
        func csi(_ letter: String) -> String { (app ? "\u{1b}O" : "\u{1b}[") + letter }
        switch key {
        case .up: sendText(csi("A"))
        case .down: sendText(csi("B"))
        case .right: sendText(csi("C"))
        case .left: sendText(csi("D"))
        case .home: sendText(csi("H"))
        case .end: sendText(csi("F"))
        case .pageUp: sendText("\u{1b}[5~")
        case .pageDown: sendText("\u{1b}[6~")
        case .escape: sendBytes([0x1B])
        case .tab: sendBytes(applyModifiers([0x09]))
        }
    }

    func pasteFromClipboard() { terminalView.paste(nil) }

    func hideKeyboard() { _ = terminalView.resignFirstResponder() }

    /// Runs a snippet as if typed.
    func run(command: String) {
        sendText(command.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r") + "\r")
    }

    // MARK: Stats

    private func startStats() {
        statsTask?.cancel()
        guard store.settings.enableServerMonitoring else { return }
        statsTask = Task { [weak self] in
            var failures = 0
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while !Task.isCancelled {
                guard let self, let client = self.client else { return }
                do {
                    let buf = try await client.executeCommand(RemoteStatsParser.script, maxResponseSize: 64 * 1024)
                    if let s = RemoteStatsParser.parse(String(buffer: buf)) {
                        failures = 0
                        self.stats = s
                    } else {
                        failures += 1
                    }
                } catch {
                    failures += 1
                    self.stats = nil
                }
                if failures >= 2 { return } // non-Linux server or exec disabled
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
        }
    }

    func refreshMonitoringSetting() {
        if store.settings.enableServerMonitoring {
            if phase == .live && statsTask == nil || statsTask?.isCancelled == true { startStats() }
        } else {
            statsTask?.cancel()
            statsTask = nil
            stats = nil
        }
    }

    // MARK: TerminalViewDelegate

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            self.cols = newCols
            self.rows = newRows
            if !self.started {
                self.startIfNeeded()
            } else if let writer = self.writer {
                try? await writer.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0)
            }
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        Task { @MainActor in self.sendBytes(self.applyModifiers(bytes)) }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        Task { @MainActor in UIApplication.shared.open(url) }
    }

    nonisolated func bell(source: TerminalView) {
        Task { @MainActor in UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) {
            Task { @MainActor in UIPasteboard.general.string = s }
        }
    }

    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Hosts the session's persistent `TerminalView` inside SwiftUI.
struct TerminalHost: UIViewRepresentable {
    @ObservedObject var session: TerminalSession
    var isActive: Bool

    final class Coordinator { var wasActive = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        attach(session.terminalView, to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if session.terminalView.superview !== container { attach(session.terminalView, to: container) }
        // Focus (and therefore show the keyboard) only when the session becomes active, never on every
        // refresh: otherwise the keyboard would come back right after the user hides it.
        let becameActive = isActive && !context.coordinator.wasActive
        context.coordinator.wasActive = isActive
        if becameActive {
            DispatchQueue.main.async {
                session.startIfNeeded()
                session.focus()
            }
        } else if !isActive, session.terminalView.isFirstResponder {
            session.blur()
        }
    }

    private func attach(_ tv: UIView, to container: UIView) {
        tv.removeFromSuperview()
        tv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tv.topAnchor.constraint(equalTo: container.topAnchor),
            tv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}


/// One-finger pan that turns vertical drags into mouse-wheel events for full-screen terminal apps.
/// While a touch is down it switches SwiftTerm's own mouse reporting off, so the same drag is not also
/// sent to the app as a click-drag (which opencode / claude interpret as text selection).
final class TerminalScrollPan: UIPanGestureRecognizer {
    weak var session: TerminalSession?
    private var suppressed = false
    private var previousAllow = true

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let session, session.wantsWheelScroll {
            session.stopInertia()
            let view = session.terminalView
            previousAllow = view.allowMouseReporting
            view.allowMouseReporting = false
            suppressed = true
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        restore()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        restore()
    }

    override func reset() {
        super.reset()
        restore()
    }

    private func restore() {
        guard suppressed else { return }
        suppressed = false
        let allow = previousAllow
        // Deferred one turn so SwiftTerm's own end-of-gesture callbacks still see reporting disabled.
        DispatchQueue.main.async { [weak self] in
            self?.session?.terminalView.allowMouseReporting = allow
        }
    }
}
