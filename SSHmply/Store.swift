import Foundation
import SwiftUI

/// Single source of truth for persisted data (servers, snippets, keys, settings) and UI state shared everywhere.
@MainActor
final class AppStore: ObservableObject {
    @Published var hosts: [Host] = []
    @Published var snippets: [Snippet] = []
    @Published var keys: [SSHKeyInfo] = []
    @Published var settings = AppSettings() {
        didSet {
            if settings.language != oldValue.language { reloadStrings() }
            if settings.appTheme != oldValue.appTheme { pal = Palette.make(settings.appTheme) }
            if loaded { saveSettingsSoon() }
        }
    }
    @Published var systemDark = false
    @Published var pal = Palette.make(.oled)
    @Published var toast: ToastMessage?

    private var loaded = false
    private var strings: [String: String] = [:]
    private var fallback: [String: String] = [:]
    private var knownHosts: [String: String] = [:]
    private var settingsTask: Task<Void, Never>?

    struct ToastMessage: Identifiable, Equatable {
        enum Kind { case info, success, error }
        let id = UUID()
        var text: String
        var kind: Kind
    }

    // MARK: Theme

    var resolvedTheme: ResolvedTheme {
        switch settings.appTheme {
        case .light: return .light
        case .dark: return .dark
        case .oled: return .oled
        case .system: return systemDark ? .dark : .light
        }
    }

    var preferredScheme: ColorScheme? {
        switch settings.appTheme {
        case .light: return .light
        case .dark, .oled: return .dark
        case .system: return nil
        }
    }

    // MARK: Init / load

    init() {
        fallback = Self.loadStrings("en")
        load()
    }

    private static func loadStrings(_ lang: String) -> [String: String] {
        guard let url = Bundle.main.url(forResource: lang, withExtension: "json", subdirectory: "i18n"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return dict
    }

    private func reloadStrings() {
        strings = Self.loadStrings(settings.language.rawValue)
    }

    func t(_ key: String, _ vars: [String: Any] = [:]) -> String {
        var s = strings[key] ?? fallback[key] ?? key
        for (k, v) in vars { s = s.replacingOccurrences(of: "{\(k)}", with: "\(v)") }
        return s
    }

    // MARK: Files

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SSHmply", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date")
        }
        return d
    }

    /// `nil` when the file does not exist; a file that cannot be parsed is moved aside, never overwritten.
    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let u = url(name)
        guard let data = try? Data(contentsOf: u) else { return nil }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(at: u, to: u.deletingPathExtension().appendingPathExtension("corrupt-\(stamp)"))
            return nil
        }
    }

    private static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func load() {
        if let s = Self.read(AppSettings.self, "settings.json") { settings = s }
        else {
            // First launch: follow the device language when we support it.
            let code = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "es"
            settings.language = Language(rawValue: code) ?? .en
        }
        pal = Palette.make(settings.appTheme)
        reloadStrings()

        if var stored = Self.read([Host].self, "hosts.json") {
            for i in stored.indices {
                stored[i].password = Keychain.get("host-pw-\(stored[i].id)")
                stored[i].passphrase = Keychain.get("host-pp-\(stored[i].id)")
            }
            hosts = stored
        } else {
            hosts = [
                Host(id: "h-rebex", name: "Rebex Test Server", hostname: "test.rebex.net", username: "demo",
                     group: "Pruebas", os: "linux", tags: ["public", "test"], password: "password"),
                Host(id: "h-sdf", name: "SDF Public UNIX", hostname: "sdf.org", username: "new",
                     group: "Pruebas", os: "debian", tags: ["public", "unix"], password: "new"),
            ]
            persistHosts()
        }

        if let s = Self.read([Snippet].self, "snippets.json") { snippets = s }
        else {
            snippets = [
                Snippet(id: "s1", title: "Uso de recursos", command: "top || htop", category: "Sistema", description: "CPU y memoria en vivo"),
                Snippet(id: "s2", title: "Contenedores Docker", command: "docker ps -a", category: "Docker", description: "Contenedores activos e inactivos"),
            ]
            Self.write(snippets, "snippets.json")
        }

        keys = Self.read([SSHKeyInfo].self, "keys.json") ?? []
        knownHosts = Self.read([String: String].self, "known_hosts.json") ?? [:]
        loaded = true
    }

    private func saveSettingsSoon() {
        settingsTask?.cancel()
        settingsTask = Task { [settings] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            Self.write(settings, "settings.json")
        }
    }

    // MARK: Hosts

    private func persistHosts() {
        for h in hosts {
            Keychain.set(h.password, for: "host-pw-\(h.id)")
            Keychain.set(h.passphrase, for: "host-pp-\(h.id)")
        }
        Self.write(hosts, "hosts.json")
    }

    func saveHost(_ host: Host) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = host } else { hosts.append(host) }
        persistHosts()
    }

    func deleteHost(_ id: String) {
        hosts.removeAll { $0.id == id }
        Keychain.remove("host-pw-\(id)")
        Keychain.remove("host-pp-\(id)")
        Self.write(hosts, "hosts.json")
    }

    func toggleFavorite(_ host: Host) {
        guard let i = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[i].isFavorite.toggle()
        persistHosts()
    }

    func touchLastConnected(_ id: String) {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[i].lastConnected = Date()
        Self.write(hosts, "hosts.json")
    }

    var groups: [String] {
        Array(Set(hosts.map { $0.trimmedGroup }.filter { !$0.isEmpty })).sorted()
    }

    // MARK: Snippets

    func saveSnippet(_ s: Snippet) {
        if let i = snippets.firstIndex(where: { $0.id == s.id }) { snippets[i] = s } else { snippets.append(s) }
        Self.write(snippets, "snippets.json")
    }

    func deleteSnippet(_ id: String) {
        snippets.removeAll { $0.id == id }
        Self.write(snippets, "snippets.json")
    }

    // MARK: Keys

    func addKey(_ info: SSHKeyInfo, privateKey: String) {
        Keychain.set(privateKey, for: "key-\(info.id)")
        keys.append(info)
        Self.write(keys, "keys.json")
    }

    func removeKey(_ id: String) {
        Keychain.remove("key-\(id)")
        keys.removeAll { $0.id == id }
        for i in hosts.indices where hosts[i].keyId == id {
            hosts[i].keyId = nil
        }
        Self.write(keys, "keys.json")
        persistHosts()
    }

    func privateKey(for id: String) -> String { Keychain.get("key-\(id)") }

    // MARK: Known hosts (trust on first use)

    enum HostKeyCheck { case trusted, learned, changed }

    nonisolated static func knownHostsKey(_ host: String, _ port: Int) -> String { "\(host.lowercased()):\(port)" }

    func checkHostKey(host: String, port: Int, key: String) -> HostKeyCheck {
        let k = Self.knownHostsKey(host, port)
        if let existing = knownHosts[k] {
            return existing == key ? .trusted : .changed
        }
        knownHosts[k] = key
        Self.write(knownHosts, "known_hosts.json")
        return .learned
    }

    func forgetHostKey(host: String, port: Int) {
        knownHosts.removeValue(forKey: Self.knownHostsKey(host, port))
        Self.write(knownHosts, "known_hosts.json")
    }

    // MARK: Toasts

    func showToast(_ text: String, _ kind: ToastMessage.Kind = .info) {
        let msg = ToastMessage(text: text, kind: kind)
        toast = msg
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if self?.toast?.id == msg.id { self?.toast = nil }
        }
    }

    // MARK: Time

    func timeAgo(_ date: Date?) -> String? {
        guard let date else { return nil }
        let mins = Int(Date().timeIntervalSince(date) / 60)
        if mins < 1 { return t("justNow") }
        if mins < 60 { return t("minutesAgo", ["n": mins]) }
        let hours = mins / 60
        if hours < 24 { return t("hoursAgo", ["n": hours]) }
        return t("daysAgo", ["n": hours / 24])
    }
}
