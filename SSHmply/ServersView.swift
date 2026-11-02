import SwiftUI

struct ServersView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    let onEdit: (Host) -> Void
    let onNew: () -> Void

    @State private var query = ""
    @State private var filter = "all"
    @State private var pings: [String: Int] = [:] // -2 = measuring, -1 = offline, otherwise milliseconds
    @State private var pendingDelete: Host?
    private let pingTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private func pingKey(_ h: Host) -> String { "\(h.id)|\(h.hostname)|\(h.port)" }

    private func runPing(_ h: Host) {
        let key = pingKey(h)
        if pings[key] == -2 { return }
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
        var result = map.keys.filter { !$0.isEmpty }.sorted().map { (name: $0, hosts: map[$0]!) }
        if let none = map[""] { result.append((name: "", hosts: none)) }
        return result
    }

    var body: some View {
        NavigationView {
            List {
                if sessions.hasSessions {
                    Section(header: Text(store.t("sessionsCount"))) {
                        ForEach(sessions.refs) { ref in
                            Button { sessions.activate(ref.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: ref.kind == .ssh ? "terminal" : "folder")
                                        .foregroundColor(store.pal.accent)
                                        .frame(width: 24)
                                    Text(sessions.title(for: ref)).foregroundColor(.primary).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundColor(.secondary)
                                }
                            }
                            .themedRow()
                        }
                    }
                }

                if store.hosts.isEmpty {
                    Section {
                        EmptyStateView(icon: "server.rack", title: store.t("emptyServersTitle"), message: store.t("emptyServersDesc"))
                        Button(action: onNew) { Label(store.t("newServer"), systemImage: "plus") }
                    }
                    .themedRow()
                } else if visible.isEmpty {
                    Section {
                        EmptyStateView(icon: "magnifyingglass", title: store.t("noResultsTitle"), message: store.t("noResultsDesc"))
                    }
                    .themedRow()
                }

                ForEach(sections, id: \.name) { section in
                    Section(header: Text(section.name.isEmpty ? (sections.count > 1 ? store.t("ungrouped") : "") : section.name)) {
                        ForEach(section.hosts) { h in row(h) }
                    }
                }
            }
            .themedList()
            .navigationTitle(store.t("serversTitle"))
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: Text(store.t("searchServers")))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Picker(selection: $filter, label: Text(store.t("serversTitle"))) {
                            Label(store.t("filterAll"), systemImage: "tray.full").tag("all")
                            Label(store.t("filterFavorites"), systemImage: "star").tag("favorites")
                            ForEach(store.groups, id: \.self) { g in
                                Label(g, systemImage: "folder").tag(g)
                            }
                        }
                    } label: {
                        Image(systemName: filter == "all" ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel(store.t("filterAll"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: onNew) { Image(systemName: "plus") }
                        .accessibilityLabel(store.t("newServer"))
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { store.hosts.forEach { h in if pings[pingKey(h)] == nil { runPing(h) } } }
        .onChange(of: store.hosts) { hosts in hosts.forEach { h in if pings[pingKey(h)] == nil { runPing(h) } } }
        .onReceive(pingTimer) { _ in store.hosts.forEach { runPing($0) } }
        .onChange(of: store.groups) { groups in if filter != "all" && filter != "favorites" && !groups.contains(filter) { filter = "all" } }
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
        let state = pings[pingKey(h)]
        HStack(spacing: 12) {
            OSIconView(os: h.os, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(h.name).font(.headline).lineLimit(1)
                    if h.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundColor(store.pal.warning) }
                }
                Text(h.address)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                LatencyLabel(value: (state == nil || state == -2) ? nil : state)
                    .onTapGesture { runPing(h) }
            }
            Spacer(minLength: 4)
            Button { sessions.openSFTP(h) } label: {
                Image(systemName: "folder")
                    .font(.system(size: 18))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("SFTP")
        }
        .contentShape(Rectangle())
        .onTapGesture { sessions.openSSH(h) }
        .themedRow()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { pendingDelete = h } label: { Label(store.t("delete"), systemImage: "trash") }
            Button { onEdit(h) } label: { Label(store.t("edit"), systemImage: "pencil") }.tint(.gray)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { store.toggleFavorite(h) } label: {
                Label(store.t(h.isFavorite ? "removeFavorite" : "addFavorite"), systemImage: h.isFavorite ? "star.slash" : "star")
            }.tint(.orange)
        }
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
        NavigationView {
            List {
                if store.hosts.isEmpty {
                    Section {
                        EmptyStateView(icon: "folder", title: store.t("emptyServersTitle"), message: store.t("emptyServersDesc"))
                        Button(action: onNew) { Label(store.t("newServer"), systemImage: "plus") }
                    }
                    .themedRow()
                } else {
                    Section(footer: Text(store.t("sftpPickDesc"))) {
                        ForEach(store.hosts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { h in
                            Button { sessions.openSFTP(h) } label: {
                                HStack(spacing: 12) {
                                    OSIconView(os: h.os, size: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(h.name).font(.headline).foregroundColor(.primary).lineLimit(1)
                                        Text(h.address)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundColor(.secondary)
                                }
                            }
                            .themedRow()
                        }
                    }
                }
            }
            .themedList()
            .navigationTitle(store.t("sftpTitle"))
            .navigationBarTitleDisplayMode(.large)
        }
        .navigationViewStyle(.stack)
    }
}
