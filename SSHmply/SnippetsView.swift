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

    private var categories: [(name: String, items: [Snippet])] {
        var map: [String: [Snippet]] = [:]
        for s in store.snippets { map[s.category.trimmingCharacters(in: .whitespaces), default: []].append(s) }
        return map.keys.sorted().map { (name: $0, items: map[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: store.t("snippetsTitle"), subtitle: store.t("snippetsDesc")) {
                Button { editor = SnippetEditorTarget(snippet: nil) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .foregroundColor(.white)
                        .background(store.pal.accent)
                        .clipShape(Circle())
                }
                .accessibilityLabel(store.t("snippetNew"))
            }
            ScrollView {
                if store.snippets.isEmpty {
                    EmptyStateView(icon: "chevron.left.forwardslash.chevron.right", title: store.t("emptySnippetsTitle"), message: store.t("emptySnippetsDesc")) {
                        Button { editor = SnippetEditorTarget(snippet: nil) } label: { Label(store.t("snippetNew"), systemImage: "plus") }
                            .buttonStyle(PrimaryButtonStyle(pal: store.pal))
                    }
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(categories, id: \.name) { cat in
                        if !cat.name.isEmpty {
                            Text(cat.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(store.pal.textSecondary)
                                .padding(.top, 8)
                                .padding(.horizontal, 4)
                        }
                        ForEach(cat.items) { s in card(s) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
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

    private func card(_ s: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.system(size: 16, weight: .semibold)).foregroundColor(store.pal.textPrimary)
                    if let d = s.description, !d.isEmpty {
                        Text(d).font(.system(size: 13)).foregroundColor(store.pal.textTertiary)
                    }
                }
                Spacer()
                Menu {
                    Button { editor = SnippetEditorTarget(snippet: s) } label: { Label(store.t("edit"), systemImage: "pencil") }
                    Button(role: .destructive) { pendingDelete = s } label: { Label(store.t("delete"), systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold))
                        .foregroundColor(store.pal.textTertiary).frame(width: 34, height: 34)
                }
            }
            Text(s.command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(store.pal.textSecondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(store.pal.input)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Button {
                    UIPasteboard.general.string = s.command
                    store.showToast(store.t("copied"), .success)
                } label: { Label(store.t("copy"), systemImage: "doc.on.doc") }
                    .buttonStyle(SecondaryButtonStyle(pal: store.pal, compact: true))
                Spacer()
                Button { sessions.runSnippet(s.command) } label: { Label(store.t("snippetRun"), systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle(pal: store.pal, compact: true))
            }
        }
        .padding(12)
        .card()
    }
}

struct SnippetEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.presentationMode) private var presentation
    let initial: Snippet?
    @State private var draft = Snippet(title: "", command: "", category: "")

    var body: some View {
        SheetScaffold(
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
            InputField(label: store.t("snippetTitle"), text: $draft.title, placeholder: store.t("snippetTitlePh"))
            InputField(label: store.t("snippetCategory"), text: $draft.category, placeholder: store.t("snippetCategoryPh"))
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: store.t("snippetCommand"))
                TextEditor(text: $draft.command)
                    .font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(store.pal.input)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            InputField(label: store.t("snippetDescription"), text: Binding(get: { draft.description ?? "" }, set: { draft.description = $0 }), placeholder: "")
        }
        .onAppear { if let initial { draft = initial } }
    }
}
