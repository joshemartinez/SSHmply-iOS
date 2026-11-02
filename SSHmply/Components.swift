import SwiftUI
import UIKit
import QuickLook

// MARK: - Page header

struct PageHeader<Trailing: View>: View {
    @EnvironmentObject var store: AppStore
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(store.pal.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundColor(store.pal.textTertiary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

// MARK: - Empty state

struct EmptyStateView<Action: View>: View {
    @EnvironmentObject var store: AppStore
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(store.pal.accentSoft).frame(width: 64, height: 64)
                Image(systemName: icon).font(.system(size: 26)).foregroundColor(store.pal.accent)
            }
            Text(title).font(.system(size: 18, weight: .semibold)).foregroundColor(store.pal.textPrimary)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(store.pal.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            action().padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

// MARK: - OS icon

struct OSIconView: View {
    @EnvironmentObject var store: AppStore
    let os: String?
    var size: CGFloat = 26

    private static let aliases = ["archlinux": "arch", "linuxmint": "mint", "mac": "macos", "apple": "macos", "rhel": "centos", "win": "windows"]
    private static let known: [String: UInt32] = [
        "ubuntu": 0xE95420, "debian": 0xD70A53, "fedora": 0x3C6EB4, "arch": 0x1793D1, "kali": 0x2A9FE0,
        "mint": 0x6BB02F, "centos": 0x932A88, "alpine": 0x0D597F, "windows": 0x00ADEF,
    ]

    var body: some View {
        let raw = (os ?? "linux").lowercased().trimmingCharacters(in: .whitespaces)
        let key = Self.aliases[raw] ?? raw
        if key == "macos" {
            Image("OS_macos").renderingMode(.template).resizable().scaledToFit()
                .foregroundColor(store.pal.textPrimary).frame(width: size, height: size)
        } else if let color = Self.known[key] {
            Image("OS_\(key)").renderingMode(.template).resizable().scaledToFit()
                .foregroundColor(Color(UIColor(hex: color))).frame(width: size, height: size)
        } else {
            Image(systemName: "server.rack").font(.system(size: size * 0.8))
                .foregroundColor(store.pal.textSecondary).frame(width: size, height: size)
        }
    }
}

// MARK: - Inputs

struct FieldLabel: View {
    @EnvironmentObject var store: AppStore
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(store.pal.textSecondary)
            .textCase(.uppercase)
    }
}

struct InputField: View {
    @EnvironmentObject var store: AppStore
    let label: String?
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var keyboard: UIKeyboardType = .default
    var mono = false
    @State private var reveal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label { FieldLabel(text: label) }
            HStack {
                Group {
                    if secure && !reveal {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(keyboard)
                .font(mono ? .system(size: 16, design: .monospaced) : .system(size: 16))
                .foregroundColor(store.pal.textPrimary)
                if secure {
                    Button { reveal.toggle() } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye").foregroundColor(store.pal.textTertiary)
                    }
                    .accessibilityLabel(store.t(reveal ? "hidePassword" : "showPassword"))
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(store.pal.input)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct SearchBar: View {
    @EnvironmentObject var store: AppStore
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(store.pal.textTertiary)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .foregroundColor(store.pal.textPrimary)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(store.pal.textTertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(store.pal.input)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct Pill: View {
    @EnvironmentObject var store: AppStore
    let title: String
    var icon: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 11)) }
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundColor(selected ? store.pal.accent : store.pal.textSecondary)
            .background(selected ? store.pal.accentSoft : store.pal.input)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sheet scaffold

struct SheetScaffold<Content: View>: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.presentationMode) private var presentation
    let title: String
    var saveLabel: String?
    var saveEnabled = true
    var onSave: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .padding(20)
            }
            .background(store.pal.window.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(store.t(onSave == nil ? "close" : "cancel")) { presentation.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveLabel ?? store.t("save")) { onSave?() }
                        .font(.system(size: 17, weight: .semibold))
                        .disabled(onSave == nil || !saveEnabled)
                        .opacity(onSave == nil ? 0 : 1)
                }
            }
        }
        .navigationViewStyle(.stack)
        .accentColor(store.pal.accent)
        .preferredColorScheme(store.preferredScheme)
    }
}

// MARK: - Toast

struct ToastView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack {
            if let toast = store.toast {
                HStack(spacing: 8) {
                    Image(systemName: icon(toast.kind)).foregroundColor(color(toast.kind))
                    Text(toast.text)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(store.pal.textPrimary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(store.pal.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(store.pal.borderStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { store.toast = nil }
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.2), value: store.toast)
        .allowsHitTesting(store.toast != nil)
    }

    private func icon(_ k: AppStore.ToastMessage.Kind) -> String {
        switch k {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ k: AppStore.ToastMessage.Kind) -> Color {
        switch k {
        case .info: return store.pal.accent
        case .success: return store.pal.success
        case .error: return store.pal.danger
        }
    }
}

// MARK: - UIKit bridges

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct IdentifiableText: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

// MARK: - Latency badge

struct LatencyBadge: View {
    @EnvironmentObject var store: AppStore
    let value: Int? // nil = measuring, -1 = offline
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(store.pal.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(store.pal.input)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var color: Color {
        guard let v = value else { return store.pal.textTertiary }
        if v < 0 { return store.pal.danger }
        return v > 300 ? store.pal.danger : (v > 120 ? store.pal.warning : store.pal.success)
    }

    private var label: String {
        guard let v = value else { return store.t("pingMeasuring") }
        return v < 0 ? store.t("pingOffline") : "\(v) ms"
    }
}
