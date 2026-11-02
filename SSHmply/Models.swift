import Foundation

// MARK: - Hosts

enum AuthType: String, Codable {
    case password
    case key
}

struct Host: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var authType: AuthType
    /// Id of a key registered in the key store (authType == .key).
    var keyId: String?
    var group: String?
    var os: String?
    var color: String?
    var isFavorite: Bool
    var tags: [String]
    var lastConnected: Date?

    // Secrets never touch the JSON file: they live in the Keychain.
    var password: String = ""
    var passphrase: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, username, authType, keyId, group, os, color, isFavorite, tags, lastConnected
    }

    init(
        id: String = uid("h"),
        name: String = "",
        hostname: String = "",
        port: Int = 22,
        username: String = "",
        authType: AuthType = .password,
        keyId: String? = nil,
        group: String? = nil,
        os: String? = "linux",
        color: String? = nil,
        isFavorite: Bool = false,
        tags: [String] = [],
        lastConnected: Date? = nil,
        password: String = "",
        passphrase: String = ""
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authType = authType
        self.keyId = keyId
        self.group = group
        self.os = os
        self.color = color
        self.isFavorite = isFavorite
        self.tags = tags
        self.lastConnected = lastConnected
        self.password = password
        self.passphrase = passphrase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        authType = try c.decodeIfPresent(AuthType.self, forKey: .authType) ?? .password
        keyId = try c.decodeIfPresent(String.self, forKey: .keyId)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        os = try c.decodeIfPresent(String.self, forKey: .os)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
    }

    var address: String {
        "\(username)@\(hostname)\(port != 22 ? ":\(port)" : "")"
    }

    var trimmedGroup: String { (group ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Snippets

struct Snippet: Identifiable, Codable, Equatable, Hashable {
    var id: String = uid("s")
    var title: String
    var command: String
    var category: String
    var description: String?
}

// MARK: - Keys

struct SSHKeyInfo: Identifiable, Codable, Equatable, Hashable {
    var id: String = uid("k")
    var name: String
    var keyType: String
    /// Public key line (`ssh-ed25519 AAAA… comment`) when it can be derived.
    var publicKey: String?
    var encrypted: Bool = false
}

// MARK: - Settings

enum ThemeChoice: String, Codable, CaseIterable {
    case system, light, dark, oled
}

enum ResolvedTheme: String {
    case light, dark, oled
}

enum Language: String, Codable, CaseIterable {
    case es, en, zh, ja

    var displayName: String {
        switch self {
        case .es: return "Español"
        case .en: return "English"
        case .zh: return "中文"
        case .ja: return "日本語"
        }
    }
}

enum CursorShape: String, Codable, CaseIterable {
    case block, underline, bar
}

enum TerminalFont: String, Codable, CaseIterable {
    case sfMono = "SF Mono"
    case menlo = "Menlo"
    case courier = "Courier New"
}

struct AppSettings: Codable, Equatable {
    var schema: Int = 2
    var appTheme: ThemeChoice = .oled
    var language: Language = .es
    var enableServerMonitoring: Bool = true
    var fontFamily: TerminalFont = .sfMono
    var fontSize: Int = 13
    var cursorStyle: CursorShape = .bar
    var cursorBlink: Bool = true
    var scrollback: Int = 5000

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        schema = (try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? 1
        appTheme = (try? c.decodeIfPresent(ThemeChoice.self, forKey: .appTheme)) ?? d.appTheme
        if schema < 2 { // v2: OLED black became the default theme
            appTheme = .oled
            schema = 2
        }
        language = (try? c.decodeIfPresent(Language.self, forKey: .language)) ?? d.language
        enableServerMonitoring = (try? c.decodeIfPresent(Bool.self, forKey: .enableServerMonitoring)) ?? d.enableServerMonitoring
        fontFamily = (try? c.decodeIfPresent(TerminalFont.self, forKey: .fontFamily)) ?? d.fontFamily
        fontSize = (try? c.decodeIfPresent(Int.self, forKey: .fontSize)) ?? d.fontSize
        cursorStyle = (try? c.decodeIfPresent(CursorShape.self, forKey: .cursorStyle)) ?? d.cursorStyle
        cursorBlink = (try? c.decodeIfPresent(Bool.self, forKey: .cursorBlink)) ?? d.cursorBlink
        scrollback = (try? c.decodeIfPresent(Int.self, forKey: .scrollback)) ?? d.scrollback
    }
}

// MARK: - SFTP

struct FileEntry: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var size: UInt64
    var isDir: Bool
    var permissions: String
    var modified: Date?
}

struct RemoteStats: Equatable {
    var cpuPercent: Double
    var ramPercent: Double
    var diskPercent: Double
}

enum TransferDirection {
    case upload, download
}

struct TransferState: Identifiable {
    var id: String
    var name: String
    var direction: TransferDirection
    var transferred: UInt64
    var total: UInt64
    var done: Bool = false
    var cancelled: Bool = false
    var error: String?
}

// MARK: - Helpers

func uid(_ prefix: String) -> String {
    let t = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
    let r = String(UInt32.random(in: 0..<UInt32.max), radix: 36)
    return "\(prefix)-\(t)-\(r)"
}

func formatBytes(_ bytes: UInt64) -> String {
    if bytes == 0 { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var i = 0
    while value >= 1024 && i < units.count - 1 {
        value /= 1024
        i += 1
    }
    if i == 0 { return "\(bytes) B" }
    return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[i])
}

func joinRemote(_ base: String, _ name: String) -> String {
    base.hasSuffix("/") ? base + name : base + "/" + name
}

func parentRemote(_ path: String) -> String {
    var parts = path.split(separator: "/").map(String.init)
    if !parts.isEmpty { parts.removeLast() }
    return "/" + parts.joined(separator: "/")
}

enum FileKind {
    case image, text, pdf, audio, video, archive, other
}

func fileKind(_ name: String) -> FileKind {
    let lower = name.lowercased()
    let ext = lower.contains(".") ? String(lower.split(separator: ".").last ?? "") : ""
    let image = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "ico"]
    let audio = ["mp3", "wav", "m4a", "flac", "aac", "ogg", "opus"]
    let video = ["mp4", "mov", "m4v", "webm"]
    let archive = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]
    let text = [
        "txt", "log", "md", "json", "yaml", "yml", "toml", "ini", "conf", "cfg", "env", "xml", "csv",
        "css", "scss", "js", "mjs", "ts", "tsx", "jsx", "html", "htm", "rs", "py", "sh", "bash", "zsh",
        "c", "h", "cpp", "hpp", "java", "go", "rb", "php", "sql", "service", "lock", "gitignore", "swift",
    ]
    if image.contains(ext) { return .image }
    if audio.contains(ext) { return .audio }
    if video.contains(ext) { return .video }
    if ext == "pdf" { return .pdf }
    if archive.contains(ext) { return .archive }
    if text.contains(ext) { return .text }
    if ["readme", "license", "makefile", "dockerfile", "authorized_keys", "known_hosts"].contains(lower) { return .text }
    return .other
}
