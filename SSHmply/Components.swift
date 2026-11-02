import SwiftUI
import UIKit
import QuickLook

// MARK: - Availability helpers (keep iOS 15 working, use newer APIs when present)

extension View {
    /// Native bottom sheet sizing on iOS 16+; plain full sheet on iOS 15.
    @ViewBuilder
    func sheetDetents(medium: Bool) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents(medium ? [.medium, .large] : [.large])
                .presentationDragIndicator(.visible)
        } else {
            self
        }
    }

    @ViewBuilder
    func hideListBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    func themedList() -> some View { modifier(ThemedListModifier()) }
    func themedRow() -> some View { modifier(ThemedRowModifier()) }
}

struct ThemedListModifier: ViewModifier {
    @EnvironmentObject var store: AppStore
    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .hideListBackground()
            .background(store.pal.window.ignoresSafeArea())
    }
}

struct ThemedRowModifier: ViewModifier {
    @EnvironmentObject var store: AppStore
    func body(content: Content) -> some View {
        content.listRowBackground(store.pal.elevated)
    }
}

// MARK: - Empty state (used as a list row / section)

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 8)
    }
}

// MARK: - OS icon

struct OSIconView: View {
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
        Group {
            if key == "macos" {
                Image("OS_macos").renderingMode(.template).resizable().scaledToFit().foregroundColor(.primary)
            } else if let color = Self.known[key] {
                Image("OS_\(key)").renderingMode(.template).resizable().scaledToFit().foregroundColor(Color(UIColor(hex: color)))
            } else {
                Image(systemName: "server.rack").resizable().scaledToFit().padding(2).foregroundColor(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Form building blocks

/// Label above the field: works at any width and in any language.
struct FormField: View {
    @EnvironmentObject var store: AppStore
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var keyboard: UIKeyboardType = .default
    var mono = false
    @State private var reveal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundColor(.secondary).lineLimit(1)
            HStack(spacing: 8) {
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
                .font(mono ? .system(.body, design: .monospaced) : .body)
                if secure {
                    Button { reveal.toggle() } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye").foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(store.t(reveal ? "hidePassword" : "showPassword"))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Native form inside a navigation sheet with Cancel / Save buttons.
struct FormSheet<Content: View>: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.presentationMode) private var presentation
    let title: String
    var saveLabel: String?
    var saveEnabled = true
    var onSave: (() -> Void)?
    var medium = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationView {
            Form { content() }
                .hideListBackground()
                .background(store.pal.window.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(store.t(onSave == nil ? "close" : "cancel")) { presentation.wrappedValue.dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saveLabel ?? store.t("save")) { onSave?() }
                            .font(.body.weight(.semibold))
                            .disabled(onSave == nil || !saveEnabled)
                            .opacity(onSave == nil ? 0 : 1)
                    }
                }
        }
        .navigationViewStyle(.stack)
        .sheetDetents(medium: medium)
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
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.horizontal, 16)
                .padding(.top, 6)
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

// MARK: - Latency

struct LatencyLabel: View {
    @EnvironmentObject var store: AppStore
    let value: Int? // nil = measuring, -1 = offline

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
    }

    private var color: Color {
        guard let v = value else { return .gray }
        if v < 0 { return store.pal.danger }
        return v > 300 ? store.pal.danger : (v > 120 ? store.pal.warning : store.pal.success)
    }

    private var label: String {
        guard let v = value else { return store.t("pingMeasuring") }
        return v < 0 ? store.t("pingOffline") : "\(v) ms"
    }
}
