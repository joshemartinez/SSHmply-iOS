import SwiftUI

enum MainTab: String, CaseIterable {
    case hosts, sftp, snippets, keys, settings

    var icon: String {
        switch self {
        case .hosts: return "server.rack"
        case .sftp: return "folder"
        case .snippets: return "chevron.left.forwardslash.chevron.right"
        case .keys: return "key"
        case .settings: return "gearshape"
        }
    }

    var titleKey: String {
        switch self {
        case .hosts: return "navServers"
        case .sftp: return "navSftp"
        case .snippets: return "navSnippets"
        case .keys: return "navKeys"
        case .settings: return "navSettings"
        }
    }
}

struct HostEditorTarget: Identifiable {
    let id = UUID()
    let host: Host?
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var tab: MainTab = .hosts
    @State private var editor: HostEditorTarget?

    var body: some View {
        ZStack {
            store.pal.window.ignoresSafeArea()

            VStack(spacing: 0) {
                Group {
                    switch tab {
                    case .hosts:
                        ServersView(onEdit: { editor = HostEditorTarget(host: $0) }, onNew: { editor = HostEditorTarget(host: nil) })
                    case .sftp:
                        SftpPickerView(onNew: { editor = HostEditorTarget(host: nil) })
                    case .snippets:
                        SnippetsView()
                    case .keys:
                        KeysView()
                    case .settings:
                        SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if sessions.hasSessions { SessionsBanner() }
                TabBarView(tab: $tab)
            }

            ToastView()
        }
        .sheet(item: $editor) { target in
            HostEditorView(initial: target.host)
                .environmentObject(store)
        }
        .fullScreenCover(isPresented: $sessions.presented) {
            SessionsView()
                .environmentObject(store)
                .environmentObject(sessions)
        }
        .onAppear { store.systemDark = colorScheme == .dark }
        .onChange(of: colorScheme) { scheme in
            store.systemDark = scheme == .dark
            sessions.applyThemeToTerminals()
        }
        .onChange(of: store.settings) { _ in sessions.applySettingsToTerminals() }
    }
}

struct TabBarView: View {
    @EnvironmentObject var store: AppStore
    @Binding var tab: MainTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon).font(.system(size: 20, weight: .regular))
                        Text(store.t(item.titleKey))
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundColor(tab == item ? store.pal.accent : store.pal.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.t(item.titleKey))
            }
        }
        .padding(.horizontal, 4)
        .background(
            store.pal.sidebar
                .overlay(Rectangle().fill(store.pal.border).frame(height: 1), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// Shown above the tab bar while sessions are running in the background.
struct SessionsBanner: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager

    var body: some View {
        Button {
            if sessions.activeId == nil, let first = sessions.refs.last { sessions.activate(first.id) } else { sessions.presented = true }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(store.pal.success).frame(width: 8, height: 8)
                Text("\(store.t("sessionsCount")): \(sessions.refs.count)")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(store.pal.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(store.pal.accentSoft)
        }
        .buttonStyle(.plain)
    }
}
