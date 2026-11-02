import SwiftUI
import UniformTypeIdentifiers

struct SFTPScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    @ObservedObject var session: SFTPSession

    @State private var importing = false
    @State private var selected: FileEntry?
    @State private var prompt: TextPromptRequest?
    @State private var deleting: FileEntry?
    @State private var shareItem: IdentifiableURL?
    @State private var previewURL: IdentifiableURL?
    @State private var previewText: IdentifiableText?

    var body: some View {
        VStack(spacing: 0) {
            switch session.phase {
            case .connecting:
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                    Text(store.t("sftpConnecting")).font(.system(size: 14)).foregroundColor(store.pal.textSecondary)
                }
                Spacer()
            case .failed(let message):
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundColor(store.pal.danger)
                    Text(store.t("sftpConnectFailed")).font(.system(size: 17, weight: .semibold)).foregroundColor(store.pal.textPrimary)
                    Text(message).font(.system(size: 14)).foregroundColor(store.pal.textSecondary).multilineTextAlignment(.center)
                    HStack {
                        Button(store.t("closeTab")) { sessions.close(session.id) }.buttonStyle(SecondaryButtonStyle(pal: store.pal))
                        Button(store.t("retry")) { Task { await session.connect() } }.buttonStyle(PrimaryButtonStyle(pal: store.pal))
                    }
                }
                .padding(24)
                Spacer()
            case .ready:
                header
                browser
                if !session.transfers.isEmpty { transfersPanel }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                for url in urls { await session.upload(localURL: url) }
            }
        }
        .sheet(item: $shareItem) { item in ActivityView(items: [item.url]) }
        .sheet(item: $previewURL) { item in QuickLookView(url: item.url).ignoresSafeArea() }
        .sheet(item: $previewText) { item in
            SheetScaffold(title: item.title) {
                Text(item.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(store.pal.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = item.text
                    store.showToast(store.t("copied"), .success)
                } label: { Label(store.t("copyText"), systemImage: "doc.on.doc") }
                    .buttonStyle(SecondaryButtonStyle(pal: store.pal, compact: true))
            }
            .environmentObject(store)
        }
        .sheet(item: $prompt) { req in
            TextPromptSheet(request: req).environmentObject(store)
        }
        .alert(item: $deleting) { entry in
            Alert(
                title: Text(store.t("deleteItemTitle", ["name": entry.name])),
                message: Text(store.t(entry.isDir ? "deleteFolderDesc" : "deleteFileDesc")),
                primaryButton: .destructive(Text(store.t("delete"))) { run { try await session.remove(entry) } },
                secondaryButton: .cancel(Text(store.t("cancel")))
            )
        }
        .confirmationDialog(selected?.name ?? "", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            if let entry = selected {
                if fileKind(entry.name) != .archive {
                    Button(store.t("preview")) { preview(entry) }
                }
                Button(store.t("download")) { download(entry, share: false) }
                Button(store.t("shareDownloaded")) { download(entry, share: true) }
                Button(store.t("rename")) { askRename(entry) }
                Button(store.t("delete"), role: .destructive) { deleting = entry }
                Button(store.t("cancel"), role: .cancel) {}
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                headerButton("chevron.left", store.t("goUp")) { Task { await session.goBack() } }
                    .opacity(session.canGoBack ? 1 : 0.35)
                    .disabled(!session.canGoBack)
                headerButton("arrow.up", store.t("goUp")) { Task { await session.goUp() } }
                    .opacity(session.path == "/" ? 0.35 : 1)
                    .disabled(session.path == "/")
                Text(session.path)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(store.pal.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                headerButton("arrow.clockwise", store.t("refresh")) { Task { await session.refresh() } }
                headerButton("folder.badge.plus", store.t("newFolder")) { askNewFolder() }
                headerButton("square.and.arrow.up", store.t("uploadFiles")) { importing = true }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(store.pal.window)
        .overlay(Rectangle().fill(store.pal.border).frame(height: 1), alignment: .bottom)
    }

    private func headerButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(store.pal.accent)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private var browser: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if session.loading && session.entries.isEmpty {
                    ProgressView().padding(.top, 40)
                } else if let err = session.listError {
                    Text(err).font(.system(size: 14)).foregroundColor(store.pal.danger).padding(24)
                } else if session.entries.isEmpty {
                    EmptyStateView(icon: "folder", title: store.t("emptyFolder"), message: "") { EmptyView() }
                }
                ForEach(session.entries) { entry in
                    Button {
                        if entry.isDir { Task { await session.list(entry.path) } } else { selected = entry }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: entry))
                                .font(.system(size: 20))
                                .foregroundColor(entry.isDir ? store.pal.accent : store.pal.textSecondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(.system(size: 15)).foregroundColor(store.pal.textPrimary).lineLimit(1)
                                HStack(spacing: 8) {
                                    if !entry.isDir { Text(formatBytes(entry.size)) }
                                    if let m = entry.modified { Text(Self.dateFormatter.string(from: m)) }
                                    Text(entry.permissions).font(.system(size: 10, design: .monospaced))
                                }
                                .font(.system(size: 11))
                                .foregroundColor(store.pal.textTertiary)
                            }
                            Spacer()
                            if entry.isDir {
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(store.pal.textTertiary)
                            } else {
                                Image(systemName: "ellipsis").foregroundColor(store.pal.textTertiary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !entry.isDir {
                            Button { preview(entry) } label: { Label(store.t("preview"), systemImage: "eye") }
                            Button { download(entry, share: false) } label: { Label(store.t("download"), systemImage: "arrow.down.circle") }
                            Button { download(entry, share: true) } label: { Label(store.t("shareDownloaded"), systemImage: "square.and.arrow.up") }
                        }
                        Button { askRename(entry) } label: { Label(store.t("rename"), systemImage: "pencil") }
                        Button(role: .destructive) { deleting = entry } label: { Label(store.t("delete"), systemImage: "trash") }
                    }
                    Divider().background(store.pal.border).padding(.leading, 56)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var transfersPanel: some View {
        VStack(spacing: 0) {
            ForEach(session.transfers) { t in
                HStack(spacing: 10) {
                    Image(systemName: t.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                        .foregroundColor(t.error != nil ? store.pal.danger : store.pal.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.name).font(.system(size: 13, weight: .medium)).foregroundColor(store.pal.textPrimary).lineLimit(1)
                        if let e = t.error {
                            Text("\(store.t("transferFailed")): \(e)").font(.system(size: 11)).foregroundColor(store.pal.danger).lineLimit(2)
                        } else if t.cancelled {
                            Text(store.t("transferCancelled")).font(.system(size: 11)).foregroundColor(store.pal.textTertiary)
                        } else if t.done {
                            Text(store.t("transferDone")).font(.system(size: 11)).foregroundColor(store.pal.success)
                        } else {
                            ProgressView(value: t.total > 0 ? min(1, Double(t.transferred) / Double(t.total)) : 0)
                            Text("\(store.t(t.direction == .upload ? "uploading" : "downloading")) · \(formatBytes(t.transferred)) / \(formatBytes(t.total))")
                                .font(.system(size: 11)).foregroundColor(store.pal.textTertiary)
                        }
                    }
                    Spacer()
                    Button {
                        if t.done { session.dismissTransfer(t.id) } else { session.cancelTransfer(t.id) }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(store.pal.textTertiary).frame(width: 30, height: 30)
                    }
                    .accessibilityLabel(store.t(t.done ? "close" : "cancel"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
        .background(store.pal.sidebar)
        .overlay(Rectangle().fill(store.pal.border).frame(height: 1), alignment: .top)
    }

    // MARK: Actions

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private func icon(for entry: FileEntry) -> String {
        if entry.isDir { return "folder.fill" }
        switch fileKind(entry.name) {
        case .image: return "photo"
        case .text: return "doc.text"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .video: return "film"
        case .archive: return "archivebox"
        case .other: return "doc"
        }
    }

    private func askNewFolder() {
        prompt = TextPromptRequest(title: store.t("newFolder"), label: store.t("folderName"), initial: "", confirm: store.t("create")) { name in
            run { try await session.makeDirectory(name) }
        }
    }

    private func askRename(_ entry: FileEntry) {
        prompt = TextPromptRequest(title: store.t("renameTitle"), label: store.t("newName"), initial: entry.name, confirm: store.t("rename")) { name in
            guard name != entry.name else { return }
            run { try await session.rename(entry, to: name) }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch {
                store.showToast(SFTPSession.message(error), .error)
            }
        }
    }

    private func download(_ entry: FileEntry, share: Bool) {
        Task {
            do {
                let url = try await session.download(entry)
                if share {
                    shareItem = IdentifiableURL(url: url)
                } else {
                    store.showToast(store.t("savedTo", ["path": "Downloads/" + url.lastPathComponent]), .success)
                }
            } catch is CancellationError {
            } catch {
                store.showToast(SFTPSession.message(error), .error)
            }
        }
    }

    private func preview(_ entry: FileEntry) {
        Task {
            do {
                if fileKind(entry.name) == .text, entry.size <= 1024 * 1024 {
                    let text = try await session.readText(entry)
                    previewText = IdentifiableText(title: entry.name, text: text)
                    return
                }
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("preview", isDirectory: true)
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let url = try await session.download(entry, to: tmp, silent: true)
                previewURL = IdentifiableURL(url: url)
            } catch is CancellationError {
            } catch {
                store.showToast("\(store.t("previewFailed")): \(SFTPSession.message(error))", .error)
            }
        }
    }
}

struct TextPromptRequest: Identifiable {
    let id = UUID()
    let title: String
    let label: String
    let initial: String
    let confirm: String
    let action: (String) -> Void
}

struct TextPromptSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.presentationMode) private var presentation
    let request: TextPromptRequest
    @State private var text = ""

    var body: some View {
        SheetScaffold(
            title: request.title,
            saveLabel: request.confirm,
            saveEnabled: !text.trimmingCharacters(in: .whitespaces).isEmpty,
            onSave: {
                let value = text.trimmingCharacters(in: .whitespaces)
                presentation.wrappedValue.dismiss()
                request.action(value)
            }
        ) {
            InputField(label: request.label, text: $text, placeholder: request.label)
        }
        .onAppear { text = request.initial }
    }
}
