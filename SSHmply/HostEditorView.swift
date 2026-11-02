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
        SheetScaffold(
            title: store.t(initial == nil ? "hostNewTitle" : "hostEditTitle"),
            saveEnabled: true,
            onSave: save
        ) {
            InputField(label: store.t("hostName"), text: $draft.name, placeholder: store.t("hostNamePh"))
            InputField(label: store.t("hostAddress"), text: $draft.hostname, placeholder: store.t("hostAddressPh"), keyboard: .URL)

            HStack(spacing: 12) {
                InputField(label: store.t("hostPort"), text: $portText, placeholder: "22", keyboard: .numberPad)
                    .frame(width: 110)
                InputField(label: store.t("hostUser"), text: $draft.username, placeholder: "root")
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: store.t("hostOs"))
                Menu {
                    ForEach(Self.osOptions, id: \.0) { value, label in
                        Button { draft.os = value } label: { Text(label) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        OSIconView(os: draft.os, size: 22)
                        Text(Self.osOptions.first { $0.0 == (draft.os ?? "linux") }?.1 ?? store.t("osGenericLinux"))
                            .foregroundColor(store.pal.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12)).foregroundColor(store.pal.textTertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(store.pal.input)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: store.t("hostAuth"))
                Picker("", selection: $draft.authType) {
                    Text(store.t("authPassword")).tag(AuthType.password)
                    Text(store.t("authKey")).tag(AuthType.key)
                }
                .pickerStyle(.segmented)
            }

            if draft.authType == .password {
                InputField(label: store.t("password"), text: $draft.password, placeholder: store.t("passwordPh"), secure: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: store.t("authKey"))
                    if store.keys.isEmpty {
                        Text(store.t("noKeysYet"))
                            .font(.system(size: 14))
                            .foregroundColor(store.pal.textTertiary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(store.pal.input)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Menu {
                            ForEach(store.keys) { k in
                                Button { draft.keyId = k.id } label: { Text("\(k.name) · \(k.keyType)") }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "key").foregroundColor(store.pal.textSecondary)
                                Text(store.keys.first { $0.id == draft.keyId }.map { "\($0.name) · \($0.keyType)" } ?? store.t("savedKeys"))
                                    .foregroundColor(draft.keyId == nil ? store.pal.textTertiary : store.pal.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12)).foregroundColor(store.pal.textTertiary)
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(store.pal.input)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                InputField(label: store.t("passphrase"), text: $draft.passphrase, placeholder: store.t("passphrasePh"), secure: true)
            }

            InputField(label: store.t("hostGroup"), text: Binding(get: { draft.group ?? "" }, set: { draft.group = $0 }), placeholder: store.t("hostGroupPh"))
            InputField(label: store.t("hostTags"), text: $tagsText, placeholder: store.t("hostTagsPh"))

            if attempted && !valid {
                Text(store.t("required")).font(.system(size: 13)).foregroundColor(store.pal.danger)
            }

            Text(store.t("secretsNoteIos"))
                .font(.system(size: 12))
                .foregroundColor(store.pal.textTertiary)

            if initial != nil {
                Button {
                    store.forgetHostKey(host: draft.hostname.trimmingCharacters(in: .whitespaces), port: Int(portText) ?? 22)
                    store.showToast(store.t("hostKeyForgotten"), .success)
                } label: {
                    Label(store.t("forgetHostKey"), systemImage: "fingerprint")
                }
                .buttonStyle(SecondaryButtonStyle(pal: store.pal, compact: true))
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
        if let g = h.group?.trimmingCharacters(in: .whitespaces), g.isEmpty { h.group = nil } else { h.group = h.group?.trimmingCharacters(in: .whitespaces) }
        if h.authType == .password { h.keyId = nil; h.passphrase = "" }
        store.saveHost(h)
        presentation.wrappedValue.dismiss()
    }
}
