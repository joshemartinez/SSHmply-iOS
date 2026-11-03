import XCTest
import AVFoundation
@testable import SSHmply

/// End-to-end tests against a throw-away local sshd started by the CI workflow
/// (127.0.0.1:2222, public-key auth). They are skipped when that server is not present.
@MainActor
final class E2ETests: XCTestCase {
    private func read(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    private var user: String? { read("/tmp/e2e_user.txt")?.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func makeStore() -> AppStore {
        AppStore()
    }

    private func host(store: AppStore, keyFile: String, name: String) throws -> Host {
        guard let user, let key = read(keyFile) else { throw XCTSkip("No e2e sshd available") }
        let type = KeyParser.detectType(key)
        let info = SSHKeyInfo(name: name, keyType: type, publicKey: nil, encrypted: false)
        store.addKey(info, privateKey: key)
        return Host(name: name, hostname: "127.0.0.1", port: 2222, username: user, authType: .key, keyId: info.id)
    }

    // MARK: SSH exec

    func testEd25519KeyAuthAndExec() async throws {
        let store = makeStore()
        let h = try host(store: store, keyFile: "/tmp/e2e_key.txt", name: "ed25519")
        let out = try await SSHFactory.exec(host: h, store: store, command: "echo hello-$((6*7))")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "hello-42")
    }

    func testRSAKeyAuth() async throws {
        let store = makeStore()
        let h = try host(store: store, keyFile: "/tmp/e2e_rsa_key.txt", name: "rsa")
        let out = try await SSHFactory.exec(host: h, store: store, command: "echo rsa-ok")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "rsa-ok")
    }

    func testGeneratedKeyCanAuthenticate() async throws {
        guard let user, let authKeysPath = read("/tmp/e2e_authkeys_path.txt")?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw XCTSkip("No e2e sshd available")
        }
        let store = makeStore()
        let generated = KeyTools.generateEd25519(comment: "generated-in-app")
        let existing = (try? String(contentsOfFile: authKeysPath, encoding: .utf8)) ?? ""
        try (existing + generated.publicLine + "\n").write(toFile: authKeysPath, atomically: true, encoding: .utf8)

        let info = SSHKeyInfo(name: "gen", keyType: "ed25519", publicKey: generated.publicLine)
        store.addKey(info, privateKey: generated.privateKey)
        let h = Host(name: "gen", hostname: "127.0.0.1", port: 2222, username: user, authType: .key, keyId: info.id)
        let out = try await SSHFactory.exec(host: h, store: store, command: "echo gen-ok")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "gen-ok")
    }

    func testPublicKeyLineMatchesSshKeygen() throws {
        guard let key = read("/tmp/e2e_key.txt"), let pub = read("/tmp/e2e_key.txt.pub") else { throw XCTSkip("No e2e sshd available") }
        let line = KeyTools.publicLine(fromOpenSSH: key, comment: "e2e")
        let expected = pub.split(separator: " ").prefix(2).joined(separator: " ")
        XCTAssertEqual(line?.split(separator: " ").prefix(2).joined(separator: " "), expected)
    }

    func testWrongKeyIsRejected() async throws {
        guard let user else { throw XCTSkip("No e2e sshd available") }
        let store = makeStore()
        let generated = KeyTools.generateEd25519(comment: "not-authorised")
        let info = SSHKeyInfo(name: "bad", keyType: "ed25519", publicKey: nil)
        store.addKey(info, privateKey: generated.privateKey)
        let h = Host(name: "bad", hostname: "127.0.0.1", port: 2222, username: user, authType: .key, keyId: info.id)
        do {
            _ = try await SSHFactory.connect(host: h, store: store)
            XCTFail("Connection should have been rejected")
        } catch {
            XCTAssertTrue(error is AppError)
        }
    }

    func testRefusedPortGivesReadableError() async throws {
        let store = makeStore()
        let h = Host(name: "x", hostname: "127.0.0.1", port: 1, username: "u", authType: .password, password: "p")
        do {
            _ = try await SSHFactory.connect(host: h, store: store)
            XCTFail("Should not connect")
        } catch {
            XCTAssertTrue(error is AppError, "got \(error)")
        }
    }

    // MARK: Host key trust

    func testHostKeyTrustOnFirstUse() async throws {
        let store = makeStore()
        let host = "tofu-\(UUID().uuidString.prefix(6)).example"
        XCTAssertEqual(store.checkHostKey(host: host, port: 22, key: "ssh-ed25519 AAAA1"), .learned)
        XCTAssertEqual(store.checkHostKey(host: host, port: 22, key: "ssh-ed25519 AAAA1"), .trusted)
        XCTAssertEqual(store.checkHostKey(host: host, port: 22, key: "ssh-ed25519 BBBB2"), .changed)
        store.forgetHostKey(host: host, port: 22)
        XCTAssertEqual(store.checkHostKey(host: host, port: 22, key: "ssh-ed25519 BBBB2"), .learned)
        store.forgetHostKey(host: host, port: 22)
    }

    // MARK: Terminal

    func testTerminalSessionRunsCommands() async throws {
        let store = makeStore()
        let h = try host(store: store, keyFile: "/tmp/e2e_key.txt", name: "term")
        let session = TerminalSession(host: h, title: "term", store: store)
        session.startIfNeeded()

        try await waitUntil(timeout: 20) { session.phase == .live }
        session.run(command: "echo term-$((20+22))")
        try await waitUntil(timeout: 15) { self.bufferText(session).contains("term-42") }

        // Typing through the keyboard path (bytes) works too, and resizing does not break the channel.
        session.sendText("echo second-$((1+1))\r")
        try await waitUntil(timeout: 15) { self.bufferText(session).contains("second-2") }

        session.close()
        XCTAssertEqual(session.phase, .ended)
    }

    func testTerminalSessionReportsFailure() async throws {
        let store = makeStore()
        let h = Host(name: "dead", hostname: "127.0.0.1", port: 1, username: "u", authType: .password, password: "p")
        let session = TerminalSession(host: h, title: "dead", store: store)
        session.startIfNeeded()
        try await waitUntil(timeout: 20) { session.phase == .ended }
        XCTAssertNotNil(session.endMessage)
    }

    private func bufferText(_ session: TerminalSession) -> String {
        String(decoding: session.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    // MARK: SFTP

    func testSFTPBrowseUploadDownloadRenameDelete() async throws {
        let store = makeStore()
        let h = try host(store: store, keyFile: "/tmp/e2e_key.txt", name: "sftp")
        let sftp = SFTPSession(host: h, store: store)
        await sftp.connect()
        XCTAssertEqual(sftp.phase, .ready, "phase: \(sftp.phase)")
        XCTAssertFalse(sftp.path.isEmpty)

        let dirName = "sshmply-e2e-\(UUID().uuidString.prefix(6))"
        try await sftp.makeDirectory(dirName)
        XCTAssertTrue(sftp.entries.contains { $0.name == dirName && $0.isDir })

        await sftp.list(joinRemote(sftp.path, dirName))
        XCTAssertTrue(sftp.entries.isEmpty)

        // Upload a file larger than one chunk so chunking and offsets are exercised.
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-upload.bin")
        try payload.write(to: local)
        await sftp.upload(localURL: local)
        let uploaded = sftp.entries.first { $0.name == "e2e-upload.bin" }
        XCTAssertNotNil(uploaded)
        XCTAssertEqual(uploaded?.size, UInt64(payload.count))

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-dl-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let downloaded = try await sftp.download(try XCTUnwrap(uploaded), to: dest, silent: true)
        XCTAssertEqual(try Data(contentsOf: downloaded), payload)

        // Text preview
        let textLocal = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-note.txt")
        try "hola sftp\nsegunda línea".write(to: textLocal, atomically: true, encoding: .utf8)
        await sftp.upload(localURL: textLocal)
        let note = try XCTUnwrap(sftp.entries.first { $0.name == "e2e-note.txt" })
        let text = try await sftp.readText(note)
        XCTAssertEqual(text, "hola sftp\nsegunda línea")

        // Uploading the same name again must not overwrite.
        await sftp.upload(localURL: textLocal)
        XCTAssertTrue(sftp.entries.contains { $0.name == "e2e-note (1).txt" })

        try await sftp.rename(note, to: "renamed.txt")
        XCTAssertTrue(sftp.entries.contains { $0.name == "renamed.txt" })
        XCTAssertFalse(sftp.entries.contains { $0.name == "e2e-note.txt" })

        // Recursive delete of the whole directory.
        await sftp.goUp()
        let dir = try XCTUnwrap(sftp.entries.first { $0.name == dirName })
        try await sftp.remove(dir)
        XCTAssertFalse(sftp.entries.contains { $0.name == dirName })
        sftp.disconnect()
    }

    // MARK: Persistence

    func testSessionReconnectsAutomaticallyAfterDrop() async throws {
        let store = makeStore()
        store.settings.autoReconnect = true
        let h = try host(store: store, keyFile: "/tmp/e2e_key.txt", name: "persist")
        let session = TerminalSession(host: h, title: "persist", store: store)
        session.startIfNeeded()
        try await waitUntil(timeout: 20) { session.phase == .live }
        session.run(command: "echo before-drop-$((2+3))")
        try await waitUntil(timeout: 15) { self.bufferText(session).contains("before-drop-5") }

        session.debugDropConnection()
        try await waitUntil(timeout: 15) { session.phase != .live }
        XCTAssertNotEqual(session.phase, .ended, "a dropped connection must reconnect, not end the session")
        try await waitUntil(timeout: 30) { session.phase == .live }

        // The scrollback survives and the new shell works.
        XCTAssertTrue(bufferText(session).contains("before-drop-5"))
        session.run(command: "echo after-drop-$((4+4))")
        try await waitUntil(timeout: 15) { self.bufferText(session).contains("after-drop-8") }
        session.close()
    }

    func testBackgroundKeeperProducesValidSilentAudio() throws {
        let wav = BackgroundKeeper.silentWav(seconds: 1, sampleRate: 8000)
        XCTAssertEqual(wav.count, 44 + 16000)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertTrue(wav.dropFirst(44).allSatisfy { $0 == 0 })
        _ = try AVAudioPlayer(data: wav) // must be playable
    }

    // MARK: Key bar

    func testKeyBarIsScrollableAndFitsAllButtons() throws {
        let store = makeStore()
        let h = Host(name: "bar", hostname: "127.0.0.1", port: 1, username: "u", authType: .password, password: "p")
        let session = TerminalSession(host: h, title: "bar", store: store)
        let bar = try XCTUnwrap(session.terminalView.inputAccessoryView as? UIInputView)
        bar.frame = CGRect(x: 0, y: 0, width: 375, height: 48) // iPhone 13 mini width
        bar.setNeedsLayout()
        bar.layoutIfNeeded()

        let scroll = try XCTUnwrap(bar.subviews.compactMap { $0 as? UIScrollView }.first)
        let buttons = scroll.subviews.compactMap { $0 as? UIButton }
        XCTAssertGreaterThan(buttons.count, 20)
        XCTAssertGreaterThan(scroll.contentSize.width, 375 * 2, "all keys must be reachable by scrolling")
        XCTAssertTrue(scroll.canCancelContentTouches)
        XCTAssertTrue(scroll.isScrollEnabled)
        for b in buttons {
            XCTAssertGreaterThan(b.frame.width, 30)
            XCTAssertLessThanOrEqual(b.frame.maxX, scroll.contentSize.width)
        }
    }

    // MARK: Pure logic

    func testRemoteStatsParser() {
        let sample = """
        cpu  1000 0 500 8000 100 0 0 0 0 0
        cpu  1100 0 550 8200 100 0 0 0 0 0
        MemTotal:        8000000 kB
        MemAvailable:    2000000 kB
        /dev/sda1 100000 42000 58000  42% /
        """
        let s = RemoteStatsParser.parse(sample)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.ramPercent ?? 0, 75, accuracy: 0.01)
        XCTAssertEqual(s?.diskPercent ?? 0, 42, accuracy: 0.01)
        XCTAssertEqual(s?.cpuPercent ?? 0, 42.857, accuracy: 0.01) // (350 - 200) / 350
        XCTAssertNil(RemoteStatsParser.parse("garbage"))
    }

    func testPingLocalSSHD() async throws {
        guard user != nil else { throw XCTSkip("No e2e sshd available") }
        let ms = await Ping.tcp(host: "127.0.0.1", port: 2222)
        XCTAssertNotNil(ms)
        let none = await Ping.tcp(host: "127.0.0.1", port: 1, timeout: 2)
        XCTAssertNil(none)
    }

    func testTranslationsAreComplete() throws {
        let bundle = Bundle(for: AppStore.self)
        var keysByLang: [String: Set<String>] = [:]
        for lang in ["es", "en", "zh", "ja"] {
            let url = try XCTUnwrap(bundle.url(forResource: lang, withExtension: "json", subdirectory: "i18n"), "missing \(lang).json")
            let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
            keysByLang[lang] = Set(dict.keys)
        }
        let all = keysByLang["en"]!
        for (lang, keys) in keysByLang {
            XCTAssertEqual(all.subtracting(keys), [], "\(lang) is missing keys")
        }
    }

    func testStringSubstitution() {
        let store = makeStore()
        store.settings.language = .en
        XCTAssertEqual(store.t("deleteServerTitle", ["name": "Prod"]), "Delete \"Prod\"?")
        store.settings.language = .es
        XCTAssertEqual(store.t("serversOther", ["n": 3]), "3 servidores")
        XCTAssertEqual(store.t("this_key_does_not_exist"), "this_key_does_not_exist")
    }

    func testModeStringAndFormatting() {
        XCTAssertEqual(SFTPSession.modeString(0o040755, isDir: true, isLink: false), "drwxr-xr-x")
        XCTAssertEqual(SFTPSession.modeString(0o100644, isDir: false, isLink: false), "-rw-r--r--")
        XCTAssertEqual(formatBytes(0), "0 B")
        XCTAssertEqual(formatBytes(1536), "1.5 KB")
        XCTAssertEqual(parentRemote("/a/b/c"), "/a/b")
        XCTAssertEqual(parentRemote("/a"), "/")
        XCTAssertEqual(joinRemote("/", "x"), "/x")
        XCTAssertEqual(joinRemote("/a", "x"), "/a/x")
    }
}
