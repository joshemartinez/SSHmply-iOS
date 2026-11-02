import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH
import Network

/// A user-facing error (message is already localised).
struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Trust-on-first-use host key validation backed by `AppStore`.
final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let check: @Sendable (String, Int, String) async -> AppStore.HostKeyCheck
    private let lock = NSLock()
    private var _changed = false

    var keyChanged: Bool {
        lock.lock(); defer { lock.unlock() }
        return _changed
    }

    init(host: String, port: Int, check: @escaping @Sendable (String, Int, String) async -> AppStore.HostKeyCheck) {
        self.host = host
        self.port = port
        self.check = check
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        let host = self.host, port = self.port
        Task {
            let result = await check(host, port, key)
            if result == .changed {
                lock.lock(); _changed = true; lock.unlock()
                validationCompletePromise.fail(AppError("host key changed"))
            } else {
                validationCompletePromise.succeed(())
            }
        }
    }
}

enum SSHFactory {
    /// Opens an authenticated SSH connection for `host`. All user-visible failures are `AppError`s.
    @MainActor
    static func connect(host: Host, store: AppStore) async throws -> SSHClient {
        let username = host.username.trimmingCharacters(in: .whitespaces)
        let hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        guard !hostname.isEmpty, !username.isEmpty else { throw AppError(store.t("required")) }

        let auth = try authMethod(for: host, store: store)
        let validator = HostKeyValidator(host: hostname, port: host.port) { h, p, k in
            await store.checkHostKey(host: h, port: p, key: k)
        }

        var settings = SSHClientSettings(
            host: hostname,
            port: host.port,
            authenticationMethod: { auth },
            hostKeyValidator: .custom(validator)
        )
        settings.algorithms = .all
        settings.connectTimeout = .seconds(15)

        do {
            return try await SSHClient.connect(to: settings)
        } catch {
            if validator.keyChanged {
                throw AppError(store.t("hostKeyChanged", ["host": hostname]))
            }
            throw AppError(describe(error, host: host, store: store))
        }
    }

    @MainActor
    private static func authMethod(for host: Host, store: AppStore) throws -> SSHAuthenticationMethod {
        let user = host.username.trimmingCharacters(in: .whitespaces)
        switch host.authType {
        case .password:
            guard !host.password.isEmpty else { throw AppError(store.t("noCredentials")) }
            return .passwordBased(username: user, password: host.password)
        case .key:
            guard let keyId = host.keyId, !keyId.isEmpty else { throw AppError(store.t("noCredentials")) }
            let text = store.privateKey(for: keyId)
            guard !text.isEmpty else { throw AppError(store.t("keyMissing")) }
            return try KeyParser.authMethod(username: user, privateKey: text, passphrase: host.passphrase, store: store)
        }
    }

    static func describe(_ error: Error, host: Host, store: AppStore) -> String {
        let text = String(describing: error)
        let lower = text.lowercased()
        if lower.contains("allauthenticationoptionsfailed") || lower.contains("authentication") || lower.contains("unsupportedpassword")
            || lower.contains("unsupportedprivatekey") {
            return store.t("authFailed")
        }
        if lower.contains("timeout") || lower.contains("timedout") || lower.contains("connecttimeout") {
            return store.t("connectTimeout", ["host": host.hostname, "port": host.port])
        }
        if lower.contains("connection refused") || lower.contains("connectionrefused") {
            return store.t("connectRefused", ["host": host.hostname, "port": host.port])
        }
        return store.t("connectFailed", ["host": host.hostname, "port": host.port, "error": (error as? LocalizedError)?.errorDescription ?? text])
    }
}

enum KeyParser {
    /// Supports OpenSSH-format Ed25519 and RSA private keys (optionally passphrase-protected).
    @MainActor
    static func authMethod(username: String, privateKey: String, passphrase: String, store: AppStore) throws -> SSHAuthenticationMethod {
        let decryption = passphrase.isEmpty ? nil : passphrase.data(using: .utf8)
        let isEncrypted = looksEncrypted(privateKey)
        if isEncrypted && decryption == nil { throw AppError(store.t("keyNeedsPassphrase")) }

        let type = try? SSHKeyDetection.detectPrivateKeyType(from: privateKey)
        do {
            if type == .rsa {
                let key = try Insecure.RSA.PrivateKey(sshRsa: privateKey, decryptionKey: decryption)
                return .rsa(username: username, privateKey: key)
            }
            if type == .ed25519 || type == nil {
                if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: privateKey, decryptionKey: decryption) {
                    return .ed25519(username: username, privateKey: key)
                }
                if type == nil, let key = try? Insecure.RSA.PrivateKey(sshRsa: privateKey, decryptionKey: decryption) {
                    return .rsa(username: username, privateKey: key)
                }
            }
            throw AppError(store.t("keyUnsupported"))
        } catch let e as AppError {
            throw e
        } catch {
            throw AppError(store.t(isEncrypted ? "keyBadPassphrase" : "keyUnsupported"))
        }
    }

    static func looksEncrypted(_ text: String) -> Bool {
        // OpenSSH format: the cipher name is stored in clear after the magic header.
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }
        let b64 = lines.joined()
        guard let data = Data(base64Encoded: b64), data.count > 40 else { return text.contains("ENCRYPTED") }
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard data.prefix(magic.count).elementsEqual(magic) else { return text.contains("ENCRYPTED") }
        var idx = magic.count
        func readLen() -> Int? {
            guard idx + 4 <= data.count else { return nil }
            let n = data[idx..<idx + 4].reduce(0) { ($0 << 8) | Int($1) }
            idx += 4
            return n
        }
        guard let n = readLen(), idx + n <= data.count else { return false }
        let cipher = String(decoding: data[idx..<idx + n], as: UTF8.self)
        return cipher != "none"
    }

    static func detectType(_ text: String) -> String {
        if let t = try? SSHKeyDetection.detectPrivateKeyType(from: text) { return t.description }
        return "unknown"
    }
}

// MARK: - Ping (TCP connect latency)

enum Ping {
    /// Milliseconds to open a TCP connection, or nil when unreachable.
    static func tcp(host: String, port: Int, timeout: TimeInterval = 4) async -> Int? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let start = Date()
            let lock = NSLock()
            var finished = false
            func finish(_ value: Int?) {
                lock.lock()
                if finished { lock.unlock(); return }
                finished = true
                lock.unlock()
                conn.cancel()
                cont.resume(returning: value)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(max(1, Int(Date().timeIntervalSince(start) * 1000)))
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}

// MARK: - Remote stats

enum RemoteStatsParser {
    static let script = "head -n1 /proc/stat; sleep 0.5; head -n1 /proc/stat; "
        + "grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; df -P / | tail -n1"

    private static func cpuTimes(_ line: String) -> (total: UInt64, idle: UInt64)? {
        let nums = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().compactMap { UInt64($0) }
        guard nums.count >= 4 else { return nil }
        let idle = nums[3] + (nums.count > 4 ? nums[4] : 0)
        return (nums.prefix(8).reduce(0, +), idle)
    }

    static func parse(_ out: String) -> RemoteStats? {
        let lines = out.split(whereSeparator: \.isNewline).map(String.init)
        let cpuLines = lines.filter { $0.hasPrefix("cpu") }
        guard cpuLines.count >= 2, let a = cpuTimes(cpuLines[0]), let b = cpuTimes(cpuLines[1]) else { return nil }
        let dt = Double(b.total >= a.total ? b.total - a.total : 0)
        let didle = Double(b.idle >= a.idle ? b.idle - a.idle : 0)
        let cpu = dt > 0 ? (dt - didle) / dt * 100 : 0

        func kb(_ key: String) -> Double? {
            guard let l = lines.first(where: { $0.hasPrefix(key) }) else { return nil }
            let parts = l.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return parts.count > 1 ? Double(parts[1]) : nil
        }
        guard let total = kb("MemTotal:"), let avail = kb("MemAvailable:") else { return nil }
        let ram = total > 0 ? (total - avail) / total * 100 : 0

        var disk = 0.0
        for l in lines.reversed() {
            if let col = l.split(whereSeparator: { $0 == " " || $0 == "\t" }).first(where: { $0.hasSuffix("%") }),
               let v = Double(col.dropLast()) {
                disk = v
                break
            }
        }
        func clamp(_ v: Double) -> Double { min(100, max(0, v)) }
        return RemoteStats(cpuPercent: clamp(cpu), ramPercent: clamp(ram), diskPercent: clamp(disk))
    }
}
