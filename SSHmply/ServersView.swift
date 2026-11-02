import SwiftUI

struct ServersView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    let onEdit: (Host) -> Void
    let onNew: () -> Void

    @State private var query = ""
    @State private var filter = "all"
    @State private var collapsed: Set<String> = []
    @State private var pings: [String: Int] = [:] // -2 = measuring, -1 = offline, otherwise milliseconds
    @State private var pendingDelete: Host?
    @State private var pingTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private func pingKey(_ h: Host) -> String { "\(h.id)|\(h.hostname)|\(h.port)" }

    private func runPing(_ h: Host) {
        let key = pingKey(h)
        if pings[key] == -2 { return } // already measuring
        pings[key] = -2
        Task {
            let ms = await Ping.tcp(host: h.hostname, port: h.port)
            pings[key] = ms ?? -1
        }
    }

    private var visible: [Host] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.hosts
            .filter { h in
                if filter == "favorites" && !h.isFavorite { return false }
                if filter != "all" && filter != "favorites" && h.trimmedGroup != filter { return false }
                if q.isEmpty { return true }
                let hay = [h.name, h.hostname, h.username, h.os ?? "", h.group ?? ""] + h.tags
                return hay.contains { $0.lowercased().contains(q) }
            }
            .sorted {
                if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private var sections: [(name: String, hosts: [Host])] {
        var map: [String: [Host]] = [:]
        for h in visible { map[h.trimmedGroup, default: []].append(h) }
        let named = map.keys.filter { !$0.isEmpty }.sorted()
        var result = named.map { (name: $0, hosts: map[$0]!) }
        if let none = map[""] { result.append((name: "", hosts: none)) }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: store.t("serversTitle"),
                subtitle: store.t(store.hosts.count == 1 ? "serversOne" : "serversOther", ["n": store.hosts.count])
            ) {
                Button(action: onNew) {
                    Label(store.t("newServer"), systemImage: "plus").labelStyle(.iconOnly)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .foregroundColor(.white)
                        .background(store.pal.accent)
                        .clipShape(Circle())
                }
                .accessibilityLabel(store.t("newServer"))
            }

            if store.hosts.isEmpty {
                ScrollView {
                    EmptyStateView(icon: "server.rack", title: store.t("emptyServersTitle"), message: store.t("emptyServersDesc")) {
                        Button(action: onNew) { Label(store.t("newServer"), systemImage: "plus") }
                            .buttonStyle(PrimaryButtonStyle(pal: store.pal))
                    }
                }
            } else {
                VStack(spacing: 10) {
                    SearchBar(text: $query, placeholder: store.t("searchServers"))
                        .padding(.horizontal, 20)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Pill(title: store.t("filterAll"), selected: filter == "all") { filter = "all" }
                            Pill(title: store.t("filterFavorites"), icon: "star.fill", selected: filter == "favorites") { filter = "favorites" }
                            ForEach(store.groups, id: \.self) { g in
                                Pill(title: g, selected: filter == g) { filter = g }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 6)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if visible.isEmpty {
                            EmptyStateView(icon: "magnifyingglass", title: store.t("noResultsTitle"), message: store.t("noResultsDesc")) { EmptyView() }
                        }
                        ForEach(sections, id: \.name) { section in
                            let key = section.name.isEmpty ? "__none__" : section.name
                            let showHeader = sections.count > 1 || !section.name.isEmpty
                            if showHeader {
                                Button {
                                    if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: collapsed.contains(key) ? "chevron.right" : "chevron.down")
                                            .font(.system(size: 11, weight: .bold))
                                        Text(section.name.isEmpty ? store.t("ungrouped") : section.name)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text("\(section.hosts.count)").font(.system(size: 12)).foregroundColor(store.pal.textTertiary)
                                        Spacer()
                                    }
                                    .foregroundColor(store.pal.textSecondary)
                                    .padding(.horizontal, 4)
                                    .padding(.top, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if !collapsed.contains(key) {
                                ForEach(section.hosts) { h in row(h) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear { store.hosts.forEach { h in if pings[pingKey(h)] == nil { runPing(h) } } }
        .onChange(of: store.hosts) { hosts in hosts.forEach { h in if pings[pingKey(h)] == nil { runPing(h) } } }
        .onReceive(pingTimer) { _ in store.hosts.forEach { runPing($0) } }
        .alert(item: $pendingDelete) { h in
            Alert(
                title: Text(store.t("deleteServerTitle", ["name": h.name])),
                message: Text(store.t("deleteServerDesc")),
                primaryButton: .destructive(Text(store.t("delete"))) {
                    sessions.closeAll(for: h.id)
                    store.deleteHost(h.id)
                },
                secondaryButton: .cancel(Text(store.t("cancel")))
            )
        }
    }

    @ViewBuilder
    private func row(_ h: Host) -> some View {
        let used = store.timeAgo(h.lastConnected)
        let state = pings[pingKey(h)]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                OSIconView(os: h.os, size: 28).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(h.name).font(.system(size: 16, weight: .semibold)).foregroundColor(store.pal.textPrimary).lineLimit(1)
                        if h.isFavorite { Image(systemName: "star.fill").font(.system(size: 11)).foregroundColor(store.pal.warning) }
                    }
                    Text(h.address)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(store.pal.textSecondary)
                        .lineLimit(1)
                    if let used {
                        Text(store.t("lastUsed", ["when": used])).font(.system(size: 11)).foregroundColor(store.pal.textTertiary)
                    }
                }
                Spacer(minLength: 4)
                Menu {
                    Button { store.toggleFavorite(h) } label: {
                        Label(store.t(h.isFavorite ? "removeFavorite" : "addFavorite"), systemImage: h.isFavorite ? "star.slash" : "star")
                    }
                    Button { onEdit(h) } label: { Label(store.t("editServer"), systemImage: "pencil") }
                    Button(role: .destructive) { pendingDelete = h } label: { Label(store.t("deleteServer"), systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(store.pal.textTertiary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
            HStack(spacing: 8) {
                LatencyBadge(value: (state == nil || state == -2) ? nil : state) { runPing(h) }
                Spacer()
                Button { sessions.openSFTP(h) } label: {
                    Label("SFTP", systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle(pal: store.pal, compact: true))
                Button { sessions.openSSH(h) } label: {
                    Label(store.t("connect"), systemImage: "terminal")
                }
                .buttonStyle(PrimaryButtonStyle(pal: store.pal, compact: true))
            }
        }
        .padding(12)
        .card()
        .contextMenu {
            Button { sessions.openSSH(h) } label: { Label(store.t("connect"), systemImage: "terminal") }
            Button { sessions.openSFTP(h) } label: { Label("SFTP", systemImage: "folder") }
            Button { store.toggleFavorite(h) } label: {
                Label(store.t(h.isFavorite ? "removeFavorite" : "addFavorite"), systemImage: h.isFavorite ? "star.slash" : "star")
            }
            Button { onEdit(h) } label: { Label(store.t("editServer"), systemImage: "pencil") }
            Button(role: .destructive) { pendingDelete = h } label: { Label(store.t("deleteServer"), systemImage: "trash") }
        }
    }
}

struct SftpPickerView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: store.t("sftpTitle"), subtitle: store.t("sftpPickDesc")) { EmptyView() }
            ScrollView {
                if store.hosts.isEmpty {
                    EmptyStateView(icon: "folder", title: store.t("emptyServersTitle"), message: store.t("emptyServersDesc")) {
                        Button(action: onNew) { Label(store.t("newServer"), systemImage: "plus") }
                            .buttonStyle(PrimaryButtonStyle(pal: store.pal))
                    }
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(store.hosts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { h in
                            Button { sessions.openSFTP(h) } label: {
                                HStack(spacing: 12) {
                                    OSIconView(os: h.os, size: 28).frame(width: 36, height: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(h.name).font(.system(size: 16, weight: .semibold)).foregroundColor(store.pal.textPrimary)
                                        Text(h.address).font(.system(size: 12, design: .monospaced)).foregroundColor(store.pal.textSecondary)
                                    }
                                    Spacer()
                                    Text(store.t("sftpExplore")).font(.system(size: 14, weight: .medium)).foregroundColor(store.pal.accent)
                                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(store.pal.textTertiary)
                                }
                                .padding(12)
                                .card()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }
}
