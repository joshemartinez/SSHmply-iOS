import SwiftUI

/// Full-screen container for every open session. A native navigation bar (Liquid Glass on iOS 26)
/// holds the session switcher and the actions menu.
struct SessionsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager

    private var activeRef: SessionRef? {
        sessions.refs.first { $0.id == sessions.activeId }
    }

    var body: some View {
        NavigationView {
            ZStack {
                store.pal.terminalBg.ignoresSafeArea()
                ForEach(sessions.refs) { ref in
                    let active = ref.id == sessions.activeId
                    Group {
                        switch ref.kind {
                        case .ssh:
                            if let s = sessions.ssh[ref.id] {
                                TerminalScreen(session: s, isActive: active && sessions.presented)
                            }
                        case .sftp:
                            if let s = sessions.sftp[ref.id] {
                                SFTPScreen(session: s)
                            }
                        }
                    }
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .zIndex(active ? 1 : 0)
                }
                ToastView().zIndex(5)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { sessions.presented = false } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel(store.t("backToList"))
                }
                ToolbarItem(placement: .principal) { switcher }
                ToolbarItem(placement: .navigationBarTrailing) { actions }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(store.preferredScheme)
        .sheet(isPresented: $sessions.snippetsRequested) {
            SnippetPickerSheet { command in
                sessions.snippetsRequested = false
                sessions.runSnippet(command)
            }
            .environmentObject(store)
        }
    }

    private var switcher: some View {
        Menu {
            ForEach(sessions.refs) { ref in
                Button {
                    sessions.activeId = ref.id
                } label: {
                    if ref.id == sessions.activeId {
                        Label(sessions.title(for: ref), systemImage: "checkmark")
                    } else {
                        Text(sessions.title(for: ref))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(activeRef.map { sessions.title(for: $0) } ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if sessions.refs.count > 1 {
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
            }
            .foregroundColor(.primary)
            .frame(maxWidth: 190)
        }
        .disabled(sessions.refs.count < 2)
    }

    @ViewBuilder
    private var actions: some View {
        if let ref = activeRef {
            if ref.kind == .ssh, let s = sessions.ssh[ref.id] {
                Menu {
                    Button { s.focus() } label: { Label(store.t("showKeyboard"), systemImage: "keyboard") }
                    Button { sessions.snippetsRequested = true } label: { Label(store.t("snippetsTitle"), systemImage: "chevron.left.forwardslash.chevron.right") }
                    Button { s.changeZoom(1) } label: { Label(store.t("zoomIn"), systemImage: "textformat.size.larger") }
                    Button { s.changeZoom(-1) } label: { Label(store.t("zoomOut"), systemImage: "textformat.size.smaller") }
                    Button { s.clearScreen() } label: { Label(store.t("clearTerminal"), systemImage: "eraser") }
                    if s.phase == .ended {
                        Button { s.reconnect() } label: { Label(store.t("reconnect"), systemImage: "arrow.clockwise") }
                    }
                    Button(role: .destructive) { sessions.close(ref.id) } label: { Label(store.t("disconnect"), systemImage: "power") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(store.t("settingsTerminal"))
            } else {
                Button(role: .destructive) { sessions.close(ref.id) } label: { Image(systemName: "power") }
                    .accessibilityLabel(store.t("disconnect"))
            }
        }
    }
}

// MARK: - Terminal screen

struct TerminalScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    @ObservedObject var session: TerminalSession
    let isActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            ZStack {
                store.pal.terminalBg
                TerminalHost(session: session, isActive: isActive)

                if session.phase == .connecting {
                    VStack {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(store.t("connectingTo", ["host": session.host.name]))
                                .font(.footnote.weight(.medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                if session.phase == .ended {
                    ZStack {
                        Color.black.opacity(0.45)
                        VStack(spacing: 12) {
                            Text(store.t("sessionEnded")).font(.headline)
                            Text(session.endMessage ?? store.t("sessionEndedNoCode", ["host": session.host.name]))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            HStack(spacing: 10) {
                                Button(store.t("closeTab")) { sessions.close(session.id) }
                                    .buttonStyle(.bordered)
                                Button { session.reconnect() } label: { Label(store.t("reconnect"), systemImage: "arrow.clockwise") }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: 320)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(20)
                    }
                }
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.phase == .live ? store.pal.success : (session.phase == .connecting ? store.pal.warning : store.pal.danger))
                .frame(width: 8, height: 8)
            Text(session.host.address)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let st = session.stats {
                HStack(spacing: 8) {
                    stat(store.t("statCpu"), st.cpuPercent, 60, 85)
                    stat(store.t("statRam"), st.ramPercent, 70, 90)
                    stat(store.t("statDisk"), st.diskPercent, 75, 90)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(store.pal.terminalBg)
    }

    private func stat(_ label: String, _ value: Double, _ warn: Double, _ bad: Double) -> some View {
        let color = value >= bad ? store.pal.danger : (value >= warn ? store.pal.warning : store.pal.success)
        return HStack(spacing: 3) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
            Text("\(Int(value.rounded()))%").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(color)
        }
    }
}

// MARK: - Snippet picker used from the terminal

struct SnippetPickerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.presentationMode) private var presentation
    let onRun: (String) -> Void
    @State private var query = ""

    private var filtered: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return store.snippets }
        return store.snippets.filter { $0.title.lowercased().contains(q) || $0.command.lowercased().contains(q) || $0.category.lowercased().contains(q) }
    }

    var body: some View {
        NavigationView {
            List {
                if filtered.isEmpty {
                    EmptyStateView(icon: "chevron.left.forwardslash.chevron.right", title: store.t("emptySnippetsTitle"), message: store.t("emptySnippetsDesc"))
                        .themedRow()
                }
                ForEach(filtered) { s in
                    Button { onRun(s.command) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.title).font(.headline).foregroundColor(.primary).lineLimit(1)
                            Text(s.command)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .themedRow()
                }
            }
            .themedList()
            .searchable(text: $query, prompt: Text(store.t("snippetsTitle")))
            .navigationTitle(store.t("snippetsTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(store.t("close")) { presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheetDetents(medium: true)
        .preferredColorScheme(store.preferredScheme)
    }
}
