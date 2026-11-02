import SwiftUI
import UniformTypeIdentifiers
import Crypto
import Citadel

/// Helpers to inspect OpenSSH private keys and build public key lines.
enum KeyTools {
    private static func sshString(_ bytes: [UInt8]) -> [UInt8] {
        let n = UInt32(bytes.count)
        return [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + bytes
    }

    static func ed25519PublicLine(raw: Data, comment: String) -> String {
        let blob = sshString(Array("ssh-ed25519".utf8)) + sshString(Array(raw))
        return "ssh-ed25519 \(Data(blob).base64EncodedString()) \(comment)".trimmingCharacters(in: .whitespaces)
    }

    /// Creates a new unencrypted Ed25519 key in OpenSSH format.
    static func generateEd25519(comment: String) -> (privateKey: String, publicLine: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (
            key.makeSSHRepresentation(comment: comment),
            ed25519PublicLine(raw: key.publicKey.rawRepresentation, comment: comment)
        )
    }

    /// Reads the (unencrypted) public key blob stored in the clear inside an OpenSSH private key file.
    static func publicLine(fromOpenSSH text: String, comment: String) -> String? {
        let b64 = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: b64) else { return nil }
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard data.count > magic.count, Array(data.prefix(magic.count)) == magic else { return nil }
        var idx = magic.count
        func readString() -> Data? {
            guard idx + 4 <= data.count else { return nil }
            let n = data[idx..<idx + 4].reduce(0) { ($0 << 8) | Int($1) }
            idx += 4
            guard n >= 0, idx + n <= data.count else { return nil }
            defer { idx += n }
            return data[idx..<idx + n]
        }
        guard readString() != nil, readString() != nil, readString() != nil else { return nil } // cipher, kdf, kdf options
        idx += 4 // number of keys
        guard let blob = readString() else { return nil }
        var typeIdx = blob.startIndex
        guard blob.count > 4 else { return nil }
        let tlen = blob[typeIdx..<typeIdx + 4].reduce(0) { ($0 << 8) | Int($1) }
        typeIdx += 4
        guard typeIdx + tlen <= blob.endIndex else { return nil }
        let type = String(decoding: blob[typeIdx..<typeIdx + tlen], as: UTF8.self)
        return "\(type) \(blob.base64EncodedString()) \(comment)".trimmingCharacters(in: .whitespaces)
    }
}

struct KeysView: View {
    @EnvironmentObject var store: AppStore
    @State private var importing = false
    @State private var showPaste = false
    @State private var pendingRemove: SSHKeyInfo?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: store.t("keysTitle"),
                subtitle: store.t(store.keys.count == 1 ? "keysOne" : "keysOther", ["n": store.keys.count])
            ) {
                Menu {
                    Button { importing = true } label: { Label(store.t("keysImport"), systemImage: "square.and.arrow.down") }
                    Button { showPaste = true } label: { Label(store.t("keysPaste"), systemImage: "doc.on.clipboard") }
                    Button { generate() } label: { Label(store.t("keysGenerate"), systemImage: "wand.and.stars") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .foregroundColor(.white)
                        .background(store.pal.accent)
                        .clipShape(Circle())
                }
                .accessibilityLabel(store.t("keysAdd"))
            }

            ScrollView {
                if store.keys.isEmpty {
                    EmptyStateView(icon: "key", title: store.t("keysEmptyTitle"), message: store.t("keysEmptyDescIos")) {
                        Button { generate() } label: { Label(store.t("keysGenerate"), systemImage: "wand.and.stars") }
                            .buttonStyle(PrimaryButtonStyle(pal: store.pal))
                    }
                }
                LazyVStack(spacing: 8) {
                    ForEach(store.keys) { k in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Image(systemName: "key.fill").font(.system(size: 18)).foregroundColor(store.pal.accent)
                                    .frame(width: 36, height: 36).background(store.pal.accentSoft).clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(k.name).font(.system(size: 16, weight: .semibold)).foregroundColor(store.pal.textPrimary)
                                    Text(k.keyType + (k.encrypted ? " · " + store.t("keyEncryptedBadge") : ""))
                                        .font(.system(size: 12)).foregroundColor(store.pal.textTertiary)
                                }
                                Spacer()
                            }
                            if let pub = k.publicKey {
                                Text(pub)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(store.pal.textSecondary)
                                    .lineLimit(2)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(store.pal.input)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            HStack {
                                if let pub = k.publicKey {
                                    Button {
                                        UIPasteboard.general.string = pub
                                        store.showToast(store.t("publicKeyCopied"), .success)
                                    } label: { Label(store.t("copyPublicKey"), systemImage: "doc.on.doc") }
                                        .buttonStyle(SecondaryButtonStyle(pal: store.pal, compact: true))
                                }
                                Spacer()
                                Button { pendingRemove = k } label: { Label(store.t("remove"), systemImage: "trash") }
                                    .buttonStyle(SecondaryButtonStyle(pal: store.pal, compact: true, danger: true))
                            }
                        }
                        .padding(12)
                        .card()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                store.showToast(store.t("keyImportFailed"), .error)
                return
            }
            addKey(text: text, name: url.deletingPathExtension().lastPathComponent)
        }
        .sheet(isPresented: $showPaste) {
            PasteKeySheet { name, text in addKey(text: text, name: name) }.environmentObject(store)
        }
        .alert(item: $pendingRemove) { k in
            Alert(
                title: Text(store.t("keyRemoveTitle", ["name": k.name])),
                message: Text(store.t("keyRemoveDescIos")),
                primaryButton: .destructive(Text(store.t("remove"))) { store.removeKey(k.id) },
                secondaryButton: .cancel(Text(store.t("cancel")))
            )
        }
    }

    private func addKey(text raw: String, name: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard text.contains("BEGIN OPENSSH PRIVATE KEY") else {
            store.showToast(store.t("keyNotOpenSSH"), .error)
            return
        }
        let type = KeyParser.detectType(text)
        guard type != "unknown" else {
            store.showToast(store.t("keyUnsupported"), .error)
            return
        }
        let label = name.trimmingCharacters(in: .whitespaces).isEmpty ? "key" : name.trimmingCharacters(in: .whitespaces)
        let info = SSHKeyInfo(
            name: label,
            keyType: type,
            publicKey: KeyTools.publicLine(fromOpenSSH: text, comment: label),
            encrypted: KeyParser.looksEncrypted(text)
        )
        store.addKey(info, privateKey: text)
        store.showToast(store.t("keyAdded"), .success)
    }

    private func generate() {
        let name = "sshmply-\(store.keys.count + 1)"
        let generated = KeyTools.generateEd25519(comment: name)
        let info = SSHKeyInfo(name: name, keyType: "ed25519", publicKey: generated.publicLine, encrypted: false)
        store.addKey(info, privateKey: generated.privateKey)
        store.showToast(store.t("keyGenerated"), .success)
    }
}

struct PasteKeySheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.presentationMode) private var presentation
    let onAdd: (String, String) -> Void
    @State private var name = ""
    @State private var text = ""

    var body: some View {
        SheetScaffold(
            title: store.t("keysPaste"),
            saveLabel: store.t("keysAdd"),
            saveEnabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onSave: {
                presentation.wrappedValue.dismiss()
                onAdd(name, text)
            }
        ) {
            InputField(label: store.t("keyName"), text: $name, placeholder: store.t("keyNamePh"))
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: store.t("keyPastePrivate"))
                TextEditor(text: $text)
                    .font(.system(size: 11, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .frame(minHeight: 220)
                    .padding(6)
                    .background(store.pal.input)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button {
                    if let s = UIPasteboard.general.string { text = s }
                } label: { Label(store.t("pasteFromClipboard"), systemImage: "doc.on.clipboard") }
                    .buttonStyle(SecondaryButtonStyle(pal: store.pal, compact: true))
            }
        }
    }
}
