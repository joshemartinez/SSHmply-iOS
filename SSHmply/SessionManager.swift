import Foundation
import SwiftUI

struct SessionRef: Identifiable, Equatable {
    let id: String
    let kind: SessionKind
    let hostId: String
}

/// Keeps every open SSH / SFTP session alive while the user navigates around the app.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var refs: [SessionRef] = [] {
        didSet { updateKeeper() }
    }
    @Published var activeId: String?
    @Published var presented = false
    @Published var snippetsRequested = false

    private(set) var ssh: [String: TerminalSession] = [:]
    private(set) var sftp: [String: SFTPSession] = [:]
    private unowned let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    var hasSessions: Bool { !refs.isEmpty }

    func title(for ref: SessionRef) -> String {
        switch ref.kind {
        case .ssh: return ssh[ref.id]?.title ?? ""
        case .sftp: return (sftp[ref.id]?.host.name ?? "") + " · SFTP"
        }
    }

    func openSSH(_ host: Host) {
        let same = refs.filter { $0.hostId == host.id && $0.kind == .ssh }.count
        let title = same > 0 ? "\(host.name) (\(same + 1))" : host.name
        let session = TerminalSession(host: host, title: title, store: store)
        session.onShowSnippets = { [weak self] in self?.snippetsRequested = true }
        ssh[session.id] = session
        refs.append(SessionRef(id: session.id, kind: .ssh, hostId: host.id))
        activate(session.id)
    }

    func openSFTP(_ host: Host) {
        if let existing = refs.first(where: { $0.hostId == host.id && $0.kind == .sftp }) {
            activate(existing.id)
            return
        }
        let session = SFTPSession(host: host, store: store)
        sftp[session.id] = session
        refs.append(SessionRef(id: session.id, kind: .sftp, hostId: host.id))
        activate(session.id)
        Task { await session.connect() }
    }

    func activate(_ id: String) {
        activeId = id
        presented = true
    }

    func close(_ id: String) {
        guard let idx = refs.firstIndex(where: { $0.id == id }) else { return }
        ssh[id]?.close()
        sftp[id]?.disconnect()
        ssh[id] = nil
        sftp[id] = nil
        refs.remove(at: idx)
        if activeId == id {
            activeId = refs.isEmpty ? nil : refs[min(idx, refs.count - 1)].id
        }
        if refs.isEmpty { presented = false }
    }

    func closeAll(for hostId: String) {
        for r in refs where r.hostId == hostId { close(r.id) }
    }

    /// The SSH session snippets should run in: the active one, else the most recent.
    var snippetTarget: TerminalSession? {
        if let id = activeId, let s = ssh[id] { return s }
        for r in refs.reversed() where r.kind == .ssh { return ssh[r.id] }
        return nil
    }

    func runSnippet(_ command: String) {
        guard let target = snippetTarget else {
            store.showToast(store.t("snippetNeedsSession"), .info)
            return
        }
        target.run(command: command)
        store.showToast(store.t("snippetSent", ["name": target.host.name]), .success)
    }

    /// Background keep-alive is only needed while something is open.
    func updateKeeper() {
        BackgroundKeeper.shared.setActive(!refs.isEmpty && store.settings.keepAliveInBackground)
    }

    /// App returned to the foreground: reconnect whatever died while iOS had us suspended.
    func resumeAll() {
        for s in ssh.values { s.resumeCheck() }
        for s in sftp.values { s.resumeCheck() }
    }

    func applySettingsToTerminals() {
        updateKeeper()
        for s in ssh.values {
            s.applySettings()
            s.refreshMonitoringSetting()
        }
    }

    func applyThemeToTerminals() {
        for s in ssh.values { s.applyTheme() }
    }
}
