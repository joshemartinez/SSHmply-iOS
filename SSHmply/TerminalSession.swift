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
final class TerminalSession: NSObject, ObservableObject, Identifiable, TerminalViewDelegate {
    enum Phase { case connecting, live, ended }

    let id = uid("ssh")
    let host: Host
    private unowned let store: AppStore

    @Published var title: String
    @Published var phase: Phase = .connecting
    @Published var endMessage: String?
    @Published var stats: RemoteStats?
    @Published var zoom = 0

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
        Task { @MainActor in self.sendBytes(bytes) }
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

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        attach(session.terminalView, to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if session.terminalView.superview !== container { attach(session.terminalView, to: container) }
        if isActive {
            DispatchQueue.main.async {
                session.startIfNeeded()
                if !session.terminalView.isFirstResponder { session.focus() }
            }
        } else if session.terminalView.isFirstResponder {
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
