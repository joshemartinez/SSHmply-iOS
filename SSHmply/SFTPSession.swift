import Foundation
import SwiftUI
import Citadel
import NIOCore

/// One SFTP connection plus the state of the remote file browser.
@MainActor
final class SFTPSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case connecting
        case ready
        case failed(String)
    }

    let id = uid("sftp")
    let host: Host
    private unowned let store: AppStore

    @Published var phase: Phase = .connecting
    @Published var path = "/"
    @Published var entries: [FileEntry] = []
    @Published var loading = false
    @Published var transfers: [TransferState] = []
    @Published var listError: String?

    private var client: SSHClient?
    private var sftp: SFTPClient?
    private var tasks: [String: () -> Void] = [:]
    private var loadedOnce = false
    private var history: [String] = []

    init(host: Host, store: AppStore) {
        self.host = host
        self.store = store
    }

    // MARK: Connection

    func connect() async {
        phase = .connecting
        do {
            let c = try await SSHFactory.connect(host: host, store: store)
            client = c
            let s = try await c.openSFTP()
            sftp = s
            let home = (try? await s.getRealPath(atPath: ".")) ?? "/"
            phase = .ready
            store.touchLastConnected(host.id)
            await list(home.isEmpty ? "/" : home)
        } catch {
            let msg = (error as? AppError)?.message ?? SSHFactory.describe(error, host: host, store: store)
            phase = .failed(msg)
        }
    }

    func disconnect() {
        for (_, cancel) in tasks { cancel() }
        tasks.removeAll()
        let s = sftp, c = client
        sftp = nil
        client = nil
        Task {
            try? await s?.close()
            try? await c?.close()
        }
    }

    // MARK: Browsing

    func list(_ target: String, pushHistory: Bool = true) async {
        guard let sftp else { return }
        loading = true
        listError = nil
        defer { loading = false }
        do {
            let canon = (try? await sftp.getRealPath(atPath: target)) ?? target
            let names = try await sftp.listDirectory(atPath: canon)
            var result: [FileEntry] = []
            for comp in names.flatMap({ $0.components }) {
                let name = comp.filename
                if name == "." || name == ".." { continue }
                let full = joinRemote(canon, name)
                let perms = comp.attributes.permissions ?? 0
                let fmt = perms & 0o170000
                var isDir = fmt == 0o040000
                var size = comp.attributes.size ?? 0
                if fmt == 0o120000 {
                    // Follow the link so a symlinked folder opens like a folder.
                    if let t = try? await sftp.getAttributes(at: full) {
                        isDir = ((t.permissions ?? 0) & 0o170000) == 0o040000
                        size = t.size ?? size
                    }
                }
                result.append(FileEntry(
                    name: name,
                    path: full,
                    size: isDir ? 0 : size,
                    isDir: isDir,
                    permissions: Self.modeString(perms, isDir: fmt == 0o040000, isLink: fmt == 0o120000),
                    modified: comp.attributes.accessModificationTime?.modificationTime
                ))
            }
            result.sort {
                if $0.isDir != $1.isDir { return $0.isDir && !$1.isDir }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            if pushHistory, loadedOnce, path != canon { history.append(path) }
            loadedOnce = true
            path = canon
            entries = result
        } catch {
            listError = Self.message(error)
        }
    }

    var canGoBack: Bool { !history.isEmpty }

    func goBack() async {
        guard let prev = history.popLast() else { return }
        await list(prev, pushHistory: false)
    }

    func goUp() async {
        guard path != "/" else { return }
        await list(parentRemote(path))
    }

    func refresh() async { await list(path, pushHistory: false) }

    nonisolated static func modeString(_ mode: UInt32, isDir: Bool, isLink: Bool) -> String {
        var s = isLink ? "l" : (isDir ? "d" : "-")
        for shift in [6, 3, 0] as [UInt32] {
            let bits = (mode >> shift) & 0o7
            s += bits & 4 != 0 ? "r" : "-"
            s += bits & 2 != 0 ? "w" : "-"
            s += bits & 1 != 0 ? "x" : "-"
        }
        return s
    }

    nonisolated static func message(_ error: Error) -> String {
        if let e = error as? AppError { return e.message }
        let text = String(describing: error)
        if text.lowercased().contains("permission") { return "Permission denied" }
        return (error as? LocalizedError)?.errorDescription ?? text
    }

    // MARK: Operations

    func makeDirectory(_ name: String) async throws {
        guard let sftp else { throw AppError(store.t("sftpNotConnected")) }
        try await sftp.createDirectory(atPath: joinRemote(path, name))
        await refresh()
    }

    func rename(_ entry: FileEntry, to newName: String) async throws {
        guard let sftp else { throw AppError(store.t("sftpNotConnected")) }
        let target = joinRemote(parentRemote(entry.path), newName)
        if (try? await sftp.getAttributes(at: target)) != nil { throw AppError(store.t("nameExists")) }
        try await sftp.rename(at: entry.path, to: target)
        await refresh()
    }

    func remove(_ entry: FileEntry) async throws {
        guard let sftp else { throw AppError(store.t("sftpNotConnected")) }
        if !entry.isDir {
            try await sftp.remove(at: entry.path)
        } else {
            var dirs = [entry.path]
            var files: [String] = []
            var stack = [entry.path]
            while let dir = stack.popLast() {
                let names = try await sftp.listDirectory(atPath: dir)
                for comp in names.flatMap({ $0.components }) {
                    if comp.filename == "." || comp.filename == ".." { continue }
                    let full = joinRemote(dir, comp.filename)
                    let fmt = (comp.attributes.permissions ?? 0) & 0o170000
                    if fmt == 0o040000 {
                        dirs.append(full)
                        stack.append(full)
                    } else {
                        files.append(full)
                    }
                }
            }
            for f in files { try await sftp.remove(at: f) }
            for d in dirs.reversed() { try await sftp.rmdir(at: d) }
        }
        await refresh()
    }

    func readText(_ entry: FileEntry, maxBytes: Int = 512 * 1024) async throws -> String {
        guard let sftp else { throw AppError(store.t("sftpNotConnected")) }
        let file = try await sftp.openFile(filePath: entry.path, flags: .read)
        var data = Data()
        var offset: UInt64 = 0
        do {
            while data.count < maxBytes {
                var chunk = try await file.read(from: offset, length: 32 * 1024)
                if chunk.readableBytes == 0 { break }
                offset += UInt64(chunk.readableBytes)
                data.append(contentsOf: chunk.readBytes(length: chunk.readableBytes) ?? [])
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
        if data.contains(0) { throw AppError(store.t("fileIsBinary")) }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Transfers

    nonisolated static var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        let first = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: first.path) { return first }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        for n in 1..<10_000 {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return first
    }

    private func update(_ id: String, _ change: (inout TransferState) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[i])
    }

    func cancelTransfer(_ id: String) {
        tasks[id]?()
    }

    func dismissTransfer(_ id: String) {
        transfers.removeAll { $0.id == id }
    }

    /// Downloads a remote file into `directory`; returns the final local URL.
    @discardableResult
    func download(_ entry: FileEntry, to directory: URL = SFTPSession.downloadsDirectory, silent: Bool = false) async throws -> URL {
        guard let sftp else { throw AppError(store.t("sftpNotConnected")) }
        let tid = uid("dl")
        let dest = Self.uniqueURL(in: directory, name: entry.name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        transfers.append(TransferState(id: tid, name: entry.name, direction: .download, transferred: 0, total: entry.size))

        let work = Task.detached { [weak self] () -> URL in
            guard FileManager.default.createFile(atPath: dest.path, contents: nil) else { throw AppError("Cannot create \(dest.lastPathComponent)") }
            let out = try FileHandle(forWritingTo: dest)
            let file = try await sftp.openFile(filePath: entry.path, flags: .read)
            var offset: UInt64 = 0
            do {
                while true {
                    try Task.checkCancellation()
                    var chunk = try await file.read(from: offset, length: 64 * 1024)
                    let n = chunk.readableBytes
                    if n == 0 { break }
                    if let bytes = chunk.readBytes(length: n) { try out.write(contentsOf: bytes) }
                    offset += UInt64(n)
                    let sofar = offset
                    await MainActor.run { self?.update(tid) { $0.transferred = sofar } }
                }
                try? out.close()
                try await file.close()
            } catch {
                try? out.close()
                try? await file.close()
                try? FileManager.default.removeItem(at: dest)
                throw error
            }
            return dest
        }
        tasks[tid] = { work.cancel() }

        do {
            let url = try await work.value
            update(tid) { $0.done = true; $0.transferred = max($0.transferred, $0.total) }
            tasks[tid] = nil
            if silent { dismissTransfer(tid) }
            return url
        } catch {
            let cancelled = error is CancellationError
            update(tid) {
                $0.done = true
                $0.cancelled = cancelled
                $0.error = cancelled ? nil : Self.message(error)
            }
            tasks[tid] = nil
            if silent { dismissTransfer(tid) }
            throw error
        }
    }

    /// Uploads a local file into the current remote directory (never overwrites: adds " (1)" etc.).
    func upload(localURL: URL, toDirectory remoteDir: String? = nil) async {
        guard let sftp else { return }
        let dir = remoteDir ?? path
        let name = localURL.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
        let tid = uid("ul")
        transfers.append(TransferState(id: tid, name: name, direction: .upload, transferred: 0, total: size))

        let scoped = localURL.startAccessingSecurityScopedResource()
        defer { if scoped { localURL.stopAccessingSecurityScopedResource() } }

        let work = Task.detached { [weak self] () -> Void in
            var target = joinRemote(dir, name)
            if (try? await sftp.getAttributes(at: target)) != nil {
                let ns = name as NSString
                let ext = ns.pathExtension
                let stem = ns.deletingPathExtension
                for n in 1..<10_000 {
                    let cand = joinRemote(dir, ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
                    if (try? await sftp.getAttributes(at: cand)) == nil { target = cand; break }
                }
            }
            let input = try FileHandle(forReadingFrom: localURL)
            defer { try? input.close() }
            let file = try await sftp.openFile(filePath: target, flags: [.write, .create, .truncate])
            var offset: UInt64 = 0
            do {
                while true {
                    try Task.checkCancellation()
                    guard let data = try input.read(upToCount: 32 * 1024), !data.isEmpty else { break }
                    try await file.write(ByteBuffer(bytes: data), at: offset)
                    offset += UInt64(data.count)
                    let sofar = offset
                    await MainActor.run { self?.update(tid) { $0.transferred = sofar } }
                }
                try await file.close()
            } catch {
                try? await file.close()
                if error is CancellationError { try? await sftp.remove(at: target) }
                throw error
            }
        }
        tasks[tid] = { work.cancel() }

        do {
            try await work.value
            update(tid) { $0.done = true; $0.transferred = $0.total }
            tasks[tid] = nil
            await refresh()
        } catch {
            let cancelled = error is CancellationError
            update(tid) {
                $0.done = true
                $0.cancelled = cancelled
                $0.error = cancelled ? nil : Self.message(error)
            }
            tasks[tid] = nil
            await refresh()
        }
    }
}
