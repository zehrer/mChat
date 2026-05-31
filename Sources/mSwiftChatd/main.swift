import Foundation
import Glibc
import mChatCore

private let kVersion        = "mSwiftChatd v0.0.2"
private let kSpamThreshold  = 5

@main
struct EchoDaemon {
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() } catch {
            fputs("Fatal: \(error)\n", stderr); exit(1)
        }
    }

    static func run() async throws {
        let dir = mCLIChatDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AccessControl.ensureWhitelist()

        let keyPair = try loadOrCreateKeyPair()
        print("mSwiftChatd pubkey : \(keyPair.publicKeyHex)")

        let backend = NostrBackend(keyPair: keyPair)
        print("Connecting to relays…")
        try await backend.connect()
        let config = DaemonConfig.load(section: "swift")
        try await backend.publishProfile(name: config.name, about: config.about)
        try await backend.publishRelayList()
        try await backend.publishDMRelayList()
        print("Profile published: \(config.name)")
        print("Relay list published (NIP-65 + NIP-17)")
        print("Listening for DMs… Ctrl+C to stop.\n")

        let startTime = Date()
        var msgCount = 0
        var knownSenders: Set<String> = []

        for await msg in await backend.incomingMessages() {
            guard !msg.fromMe else { continue }
            let from = String(msg.senderIdentifier.prefix(12))

            switch AccessControl.check(msg.senderIdentifier) {
            case .authorized:
                knownSenders.insert(msg.senderIdentifier)
                msgCount += 1
                print("[auth] \(from)…: \(msg.content)")
                let reply = dispatch(msg.content, startTime: startTime, msgCount: msgCount, knownSenders: knownSenders)
                await send(reply, to: msg.senderIdentifier, backend: backend)

            case .blocked:
                print("[blocked] \(from)…: ignored")

            case .pending(let count):
                let newCount = count + 1
                print("[pending \(newCount)/\(kSpamThreshold)] \(from)…: \(msg.content)")
                if newCount >= kSpamThreshold {
                    AccessControl.promoteToBlocked(msg.senderIdentifier)
                    print("  → blocked (spam threshold reached)")
                    await send("You have been blocked due to too many unauthorized attempts.",
                               to: msg.senderIdentifier, backend: backend)
                } else {
                    AccessControl.updatePending(msg.senderIdentifier, count: newCount)
                    await send("Your access request is still pending authorization.",
                               to: msg.senderIdentifier, backend: backend)
                }

            case .new:
                AccessControl.addPending(msg.senderIdentifier)
                print("[new] \(from)…: added to pending list")
                let welcome = """
                    Hello! This is \(kVersion).
                    Your contact request has been received and is pending admin authorization.

                    https://github.com/zehrer/mChat
                    """
                await send(welcome, to: msg.senderIdentifier, backend: backend)
            }
        }
    }

    static func send(_ text: String, to identifier: String, backend: NostrBackend) async {
        let conv = Conversation(protocol: .nostr, type: .oneToOne(peerIdentifier: identifier))
        do {
            _ = try await backend.send(text: text, in: conv)
            print("  → replied")
        } catch {
            print("  → send failed: \(error)")
        }
    }

    // MARK: - Command dispatch

    static func dispatch(_ text: String, startTime: Date, msgCount: Int, knownSenders: Set<String>) -> String {
        guard text.hasPrefix("/") else { return "echo: \(text)" }
        let parts = text.split(separator: " ", maxSplits: 1)
        let cmd   = String(parts[0])
        let args  = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        switch cmd {
        case "/ping":
            return "pong"

        case "/echo":
            return args.isEmpty ? "(empty)" : args

        case "/status":
            let uptime     = formatUptime(since: startTime)
            let relays     = NostrClient.defaultRelays.map { $0.host ?? $0.absoluteString }.joined(separator: ", ")
            let authorized = AccessControl.loadLines(AccessControl.whitelistURL).count
            let pending    = AccessControl.loadPending().count
            let blocked    = AccessControl.loadLines(AccessControl.blockedURL).count
            return """
                \(kVersion)
                Uptime: \(uptime)
                Relays (\(NostrClient.defaultRelays.count)): \(relays)
                Messages: \(msgCount)
                Known senders: \(knownSenders.count)
                Authorized: \(authorized) | Pending: \(pending) | Blocked: \(blocked)
                """

        case "/user":
            let authorized = AccessControl.loadLines(AccessControl.whitelistURL)
            let pending    = AccessControl.loadPending()
            let blocked    = AccessControl.loadLines(AccessControl.blockedURL)
            var lines: [String] = []
            authorized.forEach { lines.append("[auth]    \(String($0.prefix(12)))…") }
            pending.forEach    { lines.append("[pending] \(String($0.key.prefix(12)))… (\($0.value)/\(kSpamThreshold))") }
            blocked.forEach    { lines.append("[blocked] \(String($0.prefix(12)))…") }
            return lines.isEmpty ? "No senders yet." : lines.sorted().joined(separator: "\n")

        case "/help":
            return """
                /ping — alive check
                /echo <text> — send text back
                /status — daemon info
                /user — sender list with access state
                /help — this message
                """

        default:
            return "Unknown command: \(cmd)\nTry /help"
        }
    }

    // MARK: - Identity

    static func loadOrCreateKeyPair() throws -> NostrKeyPair {
        let keyFile = mCLIChatDir().appendingPathComponent("swift_echo.key")
        if FileManager.default.fileExists(atPath: keyFile.path),
           let hex = try? String(contentsOf: keyFile, encoding: .utf8)
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !hex.isEmpty {
            return try NostrKeyPair(privateKeyHex: hex)
        }
        let kp = try NostrKeyPair()
        try kp.privateKeyHex.write(to: keyFile, atomically: true, encoding: .utf8)
        print("Generated new identity → \(keyFile.path)")
        return kp
    }

    static func formatUptime(since start: Date) -> String {
        let secs = Int(Date().timeIntervalSince(start))
        let h = secs / 3600; let m = (secs % 3600) / 60; let s = secs % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

// MARK: - Access Control

enum SenderAccess { case authorized, pending(Int), blocked, new }

struct AccessControl {
    static var whitelistURL: URL { mCLIChatDir().appendingPathComponent("whitelist.txt") }
    static var blockedURL:   URL { mCLIChatDir().appendingPathComponent("blocked.txt") }
    static var pendingURL:   URL { mCLIChatDir().appendingPathComponent("pending.json") }

    static func check(_ pubkey: String) -> SenderAccess {
        if loadLines(whitelistURL).contains(pubkey) { return .authorized }
        if loadLines(blockedURL).contains(pubkey)   { return .blocked }
        if let count = loadPending()[pubkey]         { return .pending(count) }
        return .new
    }

    static func addPending(_ pubkey: String) {
        var p = loadPending(); p[pubkey] = 1; savePending(p)
    }

    static func updatePending(_ pubkey: String, count: Int) {
        var p = loadPending(); p[pubkey] = count; savePending(p)
    }

    static func promoteToBlocked(_ pubkey: String) {
        var p = loadPending(); p.removeValue(forKey: pubkey); savePending(p)
        appendLine(pubkey, to: blockedURL)
    }

    static func loadLines(_ url: URL) -> Set<String> {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    static func loadPending() -> [String: Int] {
        guard let data = try? Data(contentsOf: pendingURL),
              let dict = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return dict
    }

    static func savePending(_ dict: [String: Int]) {
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: pendingURL)
        }
    }

    static func appendLine(_ line: String, to url: URL) {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let sep = (existing.isEmpty || existing.hasSuffix("\n")) ? "" : "\n"
        try? (existing + sep + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func ensureWhitelist() {
        guard !FileManager.default.fileExists(atPath: whitelistURL.path) else { return }
        let header = """
            # mSwiftChatd authorized pubkeys
            # Add one hex pubkey per line to grant full access.
            # Lines starting with # are ignored.

            """
        try? header.write(to: whitelistURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Helpers

func mCLIChatDir() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mCLIChat")
}

// MARK: - DaemonConfig

struct DaemonConfig {
    let name: String
    let about: String

    static func load(section: String) -> DaemonConfig {
        let configURL = mCLIChatDir().appendingPathComponent("config.toml")
        if !FileManager.default.fileExists(atPath: configURL.path) { writeDefaultConfig(to: configURL) }
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else { return .defaults }
        return parse(content, section: section)
    }

    private static var defaults: DaemonConfig {
        DaemonConfig(name: kVersion, about: "Swift Agent Daemon https://github.com/zehrer/mChat")
    }

    private static func parse(_ content: String, section: String) -> DaemonConfig {
        var inSection = false
        var values: [String: String] = [:]
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { inSection = (line == "[\(section)]"); continue }
            guard inSection, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") { val = String(val.dropFirst().dropLast()) }
            values[key] = val
        }
        return DaemonConfig(name: values["name"] ?? defaults.name, about: values["about"] ?? defaults.about)
    }

    private static func writeDefaultConfig(to url: URL) {
        let content = """
            # mChat daemon configuration

            [swift]
            name  = "\(kVersion)"
            about = "Swift Agent Daemon https://github.com/zehrer/mChat"

            [rust]
            name  = "mRustChatd v0.0.2"
            about = "Rust Agent Daemon https://github.com/zehrer/mChat"
            """
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
