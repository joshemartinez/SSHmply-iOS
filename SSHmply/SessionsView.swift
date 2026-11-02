import SwiftUI

/// Full-screen container: a strip with every open session plus the active session's content.
struct SessionsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    @State private var showSnippets = false

    var body: some View {
        ZStack {
            store.pal.window.ignoresSafeArea()
            VStack(spacing: 0) {
                topStrip
                ZStack {
                    ForEach(sessions.refs) { ref in
                        let active = ref.id == sessions.activeId
                        Group {
                            switch ref.kind {
                            case .ssh:
                                if let s = sessions.ssh[ref.id] {
                                    TerminalScreen(session: s, isActive: active && sessions.presented, onSnippets: { showSnippets = true })
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
                }
            }
            ToastView()
        }
        .preferredColorScheme(store.preferredScheme)
        .sheet(isPresented: $showSnippets) {
            SnippetPickerSheet { command in
                showSnippets = false
                sessions.runSnippet(command)
            }
            .environmentObject(store)
        }
    }

    private var topStrip: some View {
        HStack(spacing: 8) {
            Button {
                sessions.presented = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(store.pal.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(store.pal.input)
                    .clipShape(Circle())
            }
            .accessibilityLabel(store.t("backToList"))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sessions.refs) { ref in
                        let active = ref.id == sessions.activeId
                        HStack(spacing: 6) {
                            Image(systemName: ref.kind == .ssh ? "terminal" : "folder").font(.system(size: 12))
                            Text(sessions.title(for: ref)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Button {
                                sessions.close(ref.id)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(store.t("closeTab"))
                        }
                        .foregroundColor(active ? store.pal.accent : store.pal.textSecondary)
                        .padding(.leading, 10)
                        .padding(.trailing, 4)
                        .frame(height: 34)
                        .background(active ? store.pal.accentSoft : store.pal.input)
                        .clipShape(Capsule())
                        .onTapGesture { sessions.activeId = ref.id }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(store.pal.sidebar.ignoresSafeArea(edges: .top))
        .overlay(Rectangle().fill(store.pal.border).frame(height: 1), alignment: .bottom)
    }
}

// MARK: - Terminal screen

struct TerminalScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    @ObservedObject var session: TerminalSession
    let isActive: Bool
    let onSnippets: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack {
                store.pal.terminalBg
                TerminalHost(session: session, isActive: isActive)
                    .padding(.horizontal, 4)

                if session.phase == .connecting {
                    VStack {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text(store.t("connectingTo", ["host": session.host.name]))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(store.pal.textSecondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(store.pal.elevated)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(store.pal.border, lineWidth: 1))
                        .padding(.top, 12)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                if session.phase == .ended {
                    ZStack {
                        store.pal.overlay
                        VStack(spacing: 10) {
                            Text(store.t("sessionEnded")).font(.system(size: 18, weight: .semibold)).foregroundColor(store.pal.textPrimary)
                            Text(session.endMessage ?? store.t("sessionEndedNoCode", ["host": session.host.name]))
                                .font(.system(size: 14))
                                .foregroundColor(store.pal.textSecondary)
                                .multilineTextAlignment(.center)
                            HStack(spacing: 10) {
                                Button(store.t("closeTab")) { sessions.close(session.id) }
                                    .buttonStyle(SecondaryButtonStyle(pal: store.pal))
                                Button { session.reconnect() } label: { Label(store.t("reconnect"), systemImage: "arrow.clockwise") }
                                    .buttonStyle(PrimaryButtonStyle(pal: store.pal))
                            }
                            .padding(.top, 4)
                        }
                        .padding(22)
                        .frame(maxWidth: 340)
                        .background(store.pal.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(store.pal.border, lineWidth: 1))
                        .padding(20)
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.phase == .live ? store.pal.success : (session.phase == .connecting ? store.pal.warning : store.pal.danger))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.host.name).font(.system(size: 13, weight: .semibold)).foregroundColor(store.pal.textPrimary).lineLimit(1)
                Text(session.host.address).font(.system(size: 10, design: .monospaced)).foregroundColor(store.pal.textTertiary).lineLimit(1)
            }
            if let st = session.stats {
                HStack(spacing: 6) {
                    stat(store.t("statCpu"), st.cpuPercent, 60, 85)
                    stat(store.t("statRam"), st.ramPercent, 70, 90)
                    stat(store.t("statDisk"), st.diskPercent, 75, 90)
                }
            }
            Spacer(minLength: 0)
            toolButton("textformat.size.smaller", store.t("zoomOut")) { session.changeZoom(-1) }
            toolButton("textformat.size.larger", store.t("zoomIn")) { session.changeZoom(1) }
            toolButton("chevron.left.forwardslash.chevron.right", store.t("snippetsTitle"), action: onSnippets)
            toolButton("eraser", store.t("clearTerminal")) { session.clearScreen() }
            toolButton("power", store.t("disconnect")) { sessions.close(session.id) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(store.pal.window)
        .overlay(Rectangle().fill(store.pal.border).frame(height: 1), alignment: .bottom)
    }

    private func stat(_ label: String, _ value: Double, _ warn: Double, _ bad: Double) -> some View {
        let color = value >= bad ? store.pal.danger : (value >= warn ? store.pal.warning : store.pal.success)
        return VStack(spacing: 0) {
            Text("\(Int(value.rounded()))%").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(color)
            Text(label).font(.system(size: 8)).foregroundColor(store.pal.textTertiary)
        }
    }

    private func toolButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(store.pal.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Snippet picker used from the terminal

struct SnippetPickerSheet: View {
    @EnvironmentObject var store: AppStore
    let onRun: (String) -> Void

    var body: some View {
        SheetScaffold(title: store.t("snippetsTitle")) {
            if store.snippets.isEmpty {
                EmptyStateView(icon: "chevron.left.forwardslash.chevron.right", title: store.t("emptySnippetsTitle"), message: store.t("emptySnippetsDesc")) { EmptyView() }
            }
            ForEach(store.snippets) { s in
                Button { onRun(s.command) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.title).font(.system(size: 16, weight: .semibold)).foregroundColor(store.pal.textPrimary)
                        Text(s.command).font(.system(size: 12, design: .monospaced)).foregroundColor(store.pal.textSecondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .card()
                }
                .buttonStyle(.plain)
            }
        }
    }
}
