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
        // A plain TabView: on iOS 26 it automatically gets the floating Liquid Glass tab bar.
        ZStack {
            TabView(selection: $tab) {
                ServersView(onEdit: { editor = HostEditorTarget(host: $0) }, onNew: { editor = HostEditorTarget(host: nil) })
                    .tabItem { Label(store.t(MainTab.hosts.titleKey), systemImage: MainTab.hosts.icon) }
                    .tag(MainTab.hosts)

                SftpPickerView(onNew: { editor = HostEditorTarget(host: nil) })
                    .tabItem { Label(store.t(MainTab.sftp.titleKey), systemImage: MainTab.sftp.icon) }
                    .tag(MainTab.sftp)

                SnippetsView()
                    .tabItem { Label(store.t(MainTab.snippets.titleKey), systemImage: MainTab.snippets.icon) }
                    .tag(MainTab.snippets)

                KeysView()
                    .tabItem { Label(store.t(MainTab.keys.titleKey), systemImage: MainTab.keys.icon) }
                    .tag(MainTab.keys)

                SettingsView()
                    .tabItem { Label(store.t(MainTab.settings.titleKey), systemImage: MainTab.settings.icon) }
                    .tag(MainTab.settings)
            }
            .accentColor(store.pal.accent)

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
