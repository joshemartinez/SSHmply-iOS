import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.presentationMode) private var presentation
    let initial: Host?

    @State private var draft = Host()
    @State private var portText = "22"
    @State private var tagsText = ""
    @State private var attempted = false

    private static let osOptions: [(String, String)] = [
        ("linux", "Linux"), ("ubuntu", "Ubuntu"), ("debian", "Debian"), ("fedora", "Fedora"), ("arch", "Arch Linux"),
        ("kali", "Kali Linux"), ("mint", "Linux Mint"), ("centos", "CentOS / RHEL"), ("alpine", "Alpine"),
        ("windows", "Windows"), ("macos", "macOS"),
    ]

    private var valid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.username.trimmingCharacters(in: .whitespaces).isEmpty
            && (Int(portText).map { (1...65535).contains($0) } ?? false)
    }

    var body: some View {
        FormSheet(
            title: store.t(initial == nil ? "hostNewTitle" : "hostEditTitle"),
            saveEnabled: true,
            onSave: save
        ) {
            Section {
                FormField(label: store.t("hostName"), text: $draft.name, placeholder: store.t("hostNamePh"))
                FormField(label: store.t("hostAddress"), text: $draft.hostname, placeholder: store.t("hostAddressPh"), keyboard: .URL)
                HStack(spacing: 16) {
                    FormField(label: store.t("hostUser"), text: $draft.username, placeholder: "root")
                    FormField(label: store.t("hostPort"), text: $portText, placeholder: "22", keyboard: .numberPad)
                        .frame(width: 80)
                }
                Picker(selection: Binding(get: { draft.os ?? "linux" }, set: { draft.os = $0 }), label: Text(store.t("hostOs")).lineLimit(1)) {
                    ForEach(Self.osOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(header: Text(store.t("hostAuth"))) {
                Picker("", selection: $draft.authType) {
                    Text(store.t("authPassword")).tag(AuthType.password)
                    Text(store.t("authKey")).tag(AuthType.key)
                }
                .pickerStyle(.segmented)

                if draft.authType == .password {
                    FormField(label: store.t("password"), text: $draft.password, placeholder: store.t("passwordPh"), secure: true)
                } else {
                    if store.keys.isEmpty {
                        Text(store.t("noKeysYet")).font(.subheadline).foregroundColor(.secondary)
                    } else {
                        Picker(selection: Binding(get: { draft.keyId ?? "" }, set: { draft.keyId = $0.isEmpty ? nil : $0 }), label: Text(store.t("authKey")).lineLimit(1)) {
                            Text("—").tag("")
                            ForEach(store.keys) { k in Text("\(k.name) · \(k.keyType)").tag(k.id) }
                        }
                        .pickerStyle(.menu)
                    }
                    FormField(label: store.t("passphrase"), text: $draft.passphrase, placeholder: store.t("passphrasePh"), secure: true)
                }
            }

            Section {
                FormField(label: store.t("hostGroup"), text: Binding(get: { draft.group ?? "" }, set: { draft.group = $0 }), placeholder: store.t("hostGroupPh"))
                FormField(label: store.t("hostTags"), text: $tagsText, placeholder: store.t("hostTagsPh"))
            }

            Section(footer: Text(store.t("secretsNoteIos"))) {
                if attempted && !valid {
                    Text(store.t("required")).font(.subheadline).foregroundColor(store.pal.danger)
                }
                if initial != nil {
                    Button {
                        store.forgetHostKey(host: draft.hostname.trimmingCharacters(in: .whitespaces), port: Int(portText) ?? 22)
                        store.showToast(store.t("hostKeyForgotten"), .success)
                    } label: {
                        Label(store.t("forgetHostKey"), systemImage: "touchid")
                    }
                }
            }
        }
        .onAppear {
            if let initial {
                draft = initial
                portText = String(initial.port)
                tagsText = initial.tags.joined(separator: ", ")
            }
        }
    }

    private func save() {
        attempted = true
        guard valid else { return }
        var h = draft
        h.name = h.name.trimmingCharacters(in: .whitespaces)
        h.hostname = h.hostname.trimmingCharacters(in: .whitespaces)
        h.username = h.username.trimmingCharacters(in: .whitespaces)
        h.port = Int(portText) ?? 22
        h.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let g = (h.group ?? "").trimmingCharacters(in: .whitespaces)
        h.group = g.isEmpty ? nil : g
        if h.authType == .password { h.keyId = nil; h.passphrase = "" }
        store.saveHost(h)
        presentation.wrappedValue.dismiss()
    }
}
