import Foundation

/// An SSH server to export to: a `Host` from ~/.ssh/config, or a server the user typed.
struct SSHTarget: Codable, Hashable {
    /// A `Host` alias from the config, or a host name.
    var host: String
    var user: String?
    var port: Int?
    /// A private key file. Without it, ssh uses the config, the default keys, and ssh-agent.
    var identityFile: String?

    /// "devbox", or "gavin@203.0.113.7:2222" for a typed server.
    var name: String {
        let user = user.map { "\($0)@" } ?? ""
        let port = port.map { ":\($0)" } ?? ""
        return user + host + port
    }

    /// "user@host" or "host", for scp-style paths such as "devbox:/home/gavin/inbox".
    var address: String { (user.map { "\($0)@" } ?? "") + host }

    /// The ssh options for this server, before the host.
    var options: [String] {
        var options: [String] = []
        if let user { options += ["-l", user] }
        if let port { options += ["-p", String(port)] }
        if let identityFile { options += ["-i", (identityFile as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        return options
    }
}

/// Reads the `Host` names from ~/.ssh/config and the files it includes.
enum SSHConfig {
    /// The host aliases, in file order. Patterns such as `*` or `i-*` are left out,
    /// because they are not servers that the user can pick.
    static func hosts() -> [String] {
        var hosts: [String] = []
        var seen = Set<String>()
        read(home.appendingPathComponent(".ssh/config").path, into: &hosts, seen: &seen, depth: 0)
        return hosts
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    private static func read(_ path: String, into hosts: inout [String], seen: inout Set<String>, depth: Int) {
        guard depth < 8, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in text.components(separatedBy: .newlines) {
            let words = line.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard let keyword = words.first?.lowercased(), !keyword.hasPrefix("#") else { continue }
            let values = words.dropFirst().map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            switch keyword {
            case "host":
                for value in values where value.rangeOfCharacter(from: CharacterSet(charactersIn: "*?!")) == nil {
                    if seen.insert(value).inserted { hosts.append(value) }
                }
            case "include":
                for pattern in values {
                    // A relative path is relative to ~/.ssh.
                    let expanded = (pattern as NSString).expandingTildeInPath
                    let absolute = expanded.hasPrefix("/") ? expanded : home.appendingPathComponent(".ssh/\(expanded)").path
                    for file in glob(absolute) { read(file, into: &hosts, seen: &seen, depth: depth + 1) }
                }
            default:
                break
            }
        }
    }

    private static func glob(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard Darwin.glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].flatMap { String(cString: $0) } }
    }
}

struct SSHError: LocalizedError {
    let errorDescription: String?
}

/// Runs ssh commands on one server. All commands share one connection (ControlMaster), so the
/// user logs in once for the folder listings and the upload. Call `close()` at the end.
///
/// Login uses keys and ssh-agent only. BatchMode stops ssh from asking for a password or for
/// trust in an unknown host key, because Reel has no terminal to ask in.
final class SSHConnection {
    let target: SSHTarget
    private let socketFolder: URL

    init(target: SSHTarget) {
        self.target = target
        // A socket path must stay under 104 bytes, and ssh adds a suffix to it. The user temporary
        // folder is too long, so the socket goes in /tmp, in a folder that only this user can open.
        socketFolder = URL(fileURLWithPath: "/tmp/reel-\(getuid())-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: socketFolder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    private var arguments: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
         "-o", "ControlMaster=auto", "-o", "ControlPath=\(socketFolder.path)/%C", "-o", "ControlPersist=120"]
            + target.options + ["--", target.host]
    }

    /// Ends the shared connection and removes its socket folder.
    func close() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "ControlPath=\(socketFolder.path)/%C", "-O", "exit"] + target.options + ["--", target.host]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: socketFolder)
    }

    // MARK: - Commands

    struct Listing {
        /// The absolute path of the folder.
        let path: String
        let folders: [String]
        let files: [String]
    }

    /// Lists a folder. `path` can start with "~". nil is the home folder.
    func list(_ path: String?) async throws -> Listing {
        let cd = path.map { "cd -- \(Self.remotePath($0))" } ?? "cd"
        let output = try await run("\(cd) && pwd && ls -1Ap")
        var lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { throw SSHError(errorDescription: "The server sent no folder listing.") }
        let folder = lines.removeFirst()
        let names = lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Listing(path: folder,
                       folders: names.filter { $0.hasSuffix("/") }.map { String($0.dropLast()) },
                       files: names.filter { !$0.hasSuffix("/") })
    }

    func makeFolder(_ path: String) async throws {
        _ = try await run("mkdir -p -- \(Self.remotePath(path))")
    }

    func exists(_ path: String) async throws -> Bool {
        try await run("if test -e \(Self.remotePath(path)); then echo yes; fi").contains("yes")
    }

    /// Runs a shell command on the server and returns its output.
    private func run(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.runBlocking(command) })
            }
        }
    }

    /// Runs a shell command on the server and returns its output. It blocks.
    private func runBlocking(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments + [command]
        let output = Pipe(), errors = ErrorCollector()
        process.standardOutput = output
        process.standardError = errors.pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw errors.error(status: process.terminationStatus) }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Uploads

    /// Sends one file. It blocks, so call it off the main thread.
    /// `progress` gets 0...1. It returns false to stop, and the upload then throws `CancellationError`.
    ///
    /// The file goes to "name.part" first. Only after all bytes are sent does a second command
    /// rename it, so a stopped upload never leaves a partial file under the real name.
    func upload(_ file: URL, to path: String, progress: (Double) -> Bool) throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let part = Self.remotePath(path + ".part")
        do {
            try send(command: "cat > \(part)", total: size, progress: progress) { input.readData(ofLength: 1 << 18) }
            _ = try runBlocking("mv -f -- \(part) \(Self.remotePath(path))")
        } catch {
            _ = try? runBlocking("rm -f -- \(part)")
            throw error
        }
    }

    /// Sends files from one local folder into a folder on the server, as one tar stream.
    /// It blocks, so call it off the main thread.
    func upload(_ files: [URL], to folder: String, progress: (Double) -> Bool) throws {
        guard let local = files.first?.deletingLastPathComponent() else { return }
        let size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) + 1024 }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // No macOS metadata, so tar on Linux does not warn about unknown headers.
        tar.environment = ["COPYFILE_DISABLE": "1"]
        tar.arguments = ["--no-mac-metadata", "--no-xattrs", "-cf", "-", "-C", local.path] + files.map(\.lastPathComponent)
        let stream = Pipe()
        tar.standardOutput = stream
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        defer { if tar.isRunning { tar.terminate() } }
        let destination = Self.remotePath(folder)
        try send(command: "mkdir -p -- \(destination) && tar -xf - -C \(destination)", total: size, progress: progress) {
            stream.fileHandleForReading.readData(ofLength: 1 << 18)
        }
        tar.waitUntilExit()
    }

    /// Runs `command` on the server and writes the chunks to its input until a chunk is empty.
    private func send(command: String, total: Int, progress: (Double) -> Bool, next: () -> Data) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments + [command]
        let input = Pipe(), errors = ErrorCollector()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors.pipe
        try process.run()

        var sent = 0
        do {
            while true {
                let chunk = next()
                if chunk.isEmpty { break }
                try input.fileHandleForWriting.write(contentsOf: chunk)
                sent += chunk.count
                guard progress(total > 0 ? min(Double(sent) / Double(total), 1) : 0) else {
                    process.terminate()
                    throw CancellationError()
                }
            }
            try input.fileHandleForWriting.close()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // ssh ended early. Its own message says why.
            process.waitUntilExit()
            throw errors.error(status: process.terminationStatus)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw errors.error(status: process.terminationStatus) }
    }

    // MARK: - Helpers

    /// Quotes a path for the remote shell. A leading "~" stays outside the quotes, so the shell expands it.
    static func remotePath(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") { return "~/" + quote(String(path.dropFirst(2))) }
        return quote(path)
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Collects what ssh writes to stderr, and turns it into an error message.
private final class ErrorCollector: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var data = Data()

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.withLock { self.data.append(chunk) }
        }
    }

    deinit { pipe.fileHandleForReading.readabilityHandler = nil }

    func error(status: Int32) -> SSHError {
        let text = lock.withLock { String(decoding: data, as: UTF8.self) }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last else { return SSHError(errorDescription: "ssh ended with status \(status).") }
        if last.contains("Host key verification failed") {
            return SSHError(errorDescription: "The server's host key is not trusted yet. Connect once with ssh in Terminal to trust it, then export again.")
        }
        if last.contains("Permission denied") {
            return SSHError(errorDescription: "The server refused the login. Reel logs in with your SSH keys and ssh-agent only. \(last)")
        }
        return SSHError(errorDescription: last)
    }
}
