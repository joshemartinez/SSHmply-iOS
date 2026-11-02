import SwiftUI

struct SnippetEditorTarget: Identifiable {
    let id = UUID()
    let snippet: Snippet?
}

struct SnippetsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionManager
    @State private var editor: SnippetEditorTarget?
    @State private var pendingDelete: Snippet?
    @State private var query = ""

    private var categories: [(name: String, items: [Snippet])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? store.snippets : store.snippets.filter {
            $0.title.lowercased().contains(q) || $0.command.lowercased().contains(q) || $0.category.lowercased().contains(q)
        }
        var map: [String: [Snippet]] = [:]
        for s in list { map[s.category.trimmingCharacters(in: .whitespaces), default: []].append(s) }
        return map.keys.sorted().map { (name: $0, items: map[$0]!) }
    }

    var body: some View {
        NavigationView {
            List {
                if store.snippets.isEmpty {
                    Section {
                        EmptyStateView(icon: "chevron.left.forwardslash.chevron.right", title: store.t("emptySnippetsTitle"), message: store.t("emptySnippetsDesc"))
                        Button { editor = SnippetEditorTarget(snippet: nil) } label: { Label(store.t("snippetNew"), systemImage: "plus") }
                    }
                    .themedRow()
                }
                ForEach(categories, id: \.name) { cat in
                    Section(header: Text(cat.name)) {
                        ForEach(cat.items) { s in
                            Button { sessions.runSnippet(s.command) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.title).font(.headline).foregroundColor(.primary).lineLimit(1)
                                    Text(s.command)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                    if let d = s.description, !d.isEmpty {
                                        Text(d).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .themedRow()
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = s } label: { Label(store.t("delete"), systemImage: "trash") }
                                Button { editor = SnippetEditorTarget(snippet: s) } label: { Label(store.t("edit"), systemImage: "pencil") }.tint(.gray)
                            }
                            .contextMenu {
                                Button { sessions.runSnippet(s.command) } label: { Label(store.t("snippetRun"), systemImage: "play.fill") }
                                Button {
                                    UIPasteboard.general.string = s.command
                                    store.showToast(store.t("copied"), .success)
                                } label: { Label(store.t("copy"), systemImage: "doc.on.doc") }
                                Button { editor = SnippetEditorTarget(snippet: s) } label: { Label(store.t("edit"), systemImage: "pencil") }
                                Button(role: .destructive) { pendingDelete = s } label: { Label(store.t("delete"), systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .themedList()
            .searchable(text: $query, prompt: Text(store.t("snippetsTitle")))
            .navigationTitle(store.t("snippetsTitle"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { editor = SnippetEditorTarget(snippet: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel(store.t("snippetNew"))
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(item: $editor) { target in
            SnippetEditorView(initial: target.snippet).environmentObject(store)
        }
        .alert(item: $pendingDelete) { s in
            Alert(
                title: Text(store.t("snippetDeleteTitle", ["title": s.title])),
                message: Text(store.t("irreversible")),
                primaryButton: .destructive(Text(store.t("delete"))) { store.deleteSnippet(s.id) },
                secondaryButton: .cancel(Text(store.t("cancel")))
            )
        }
    }
}

struct SnippetEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.presentationMode) private var presentation
    let initial: Snippet?
    @State private var draft = Snippet(title: "", command: "", category: "")

    var body: some View {
        FormSheet(
            title: store.t(initial == nil ? "snippetNew" : "snippetEdit"),
            saveEnabled: !draft.title.trimmingCharacters(in: .whitespaces).isEmpty && !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onSave: {
                var s = draft
                s.title = s.title.trimmingCharacters(in: .whitespaces)
                s.category = s.category.trimmingCharacters(in: .whitespaces)
                store.saveSnippet(s)
                presentation.wrappedValue.dismiss()
            }
        ) {
            Section {
                FormField(label: store.t("snippetTitle"), text: $draft.title, placeholder: store.t("snippetTitlePh"))
                FormField(label: store.t("snippetCategory"), text: $draft.category, placeholder: store.t("snippetCategoryPh"))
                FormField(label: store.t("snippetDescription"), text: Binding(get: { draft.description ?? "" }, set: { draft.description = $0 }))
            }
            Section(header: Text(store.t("snippetCommand"))) {
                TextEditor(text: $draft.command)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .frame(minHeight: 120)
            }
        }
        .onAppear { if let initial { draft = initial } }
    }
}
