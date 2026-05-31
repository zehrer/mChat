import Foundation
import Glibc
import mChatCore

private let kVersion = "mSwiftChatd v0.0.2"

@main
struct EchoDaemon {
    static func main() async {
        setbuf(stdout, nil)
        do {
            try await run()
        } catch {
            fputs("Fatal: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
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
            print("[\(shortTime(msg.timestamp))] \(from)…: \(msg.content)")

            knownSenders.insert(msg.senderIdentifier)
            msgCount += 1

            let reply = dispatch(
                msg.content,
                startTime: startTime,
                msgCount: msgCount,
                knownSenders: knownSenders
            )
            let conv = Conversation(
                protocol: .nostr,
                type: .oneToOne(peerIdentifier: msg.senderIdentifier)
            )
            do {
                _ = try await backend.send(text: reply, in: conv)
                print("  → replied")
            } catch {
                print("  → send failed: \(error)")
            }
        }
    }

    // MARK: - Command dispatch

    static func dispatch(_ text: String, startTime: Date, msgCount: Int, knownSenders: Set<String>) -> String {
        guard text.hasPrefix("/") else { return "echo: \(text)" }
        let parts = text.split(separator: " ", maxSplits: 1)
        let cmd = String(parts[0])
        let args = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        switch cmd {
        case "/ping":
            return "pong"

        case "/echo":
            return args.isEmpty ? "(empty)" : args

        case "/status":
            let uptime = formatUptime(since: startTime)
            let relays = NostrClient.defaultRelays.map { $0.host ?? $0.absoluteString }.joined(separator: ", ")
            return """
            \(kVersion)
            Uptime: \(uptime)
            Relays (\(NostrClient.defaultRelays.count)): \(relays)
            Messages: \(msgCount)
            Known senders: \(knownSenders.count)
            """

        case "/user":
            if knownSenders.isEmpty { return "No known senders yet." }
            let list = knownSenders.map { "• \(String($0.prefix(12)))…" }.joined(separator: "\n")
            return "Known senders (\(knownSenders.count)):\n\(list)"

        case "/help":
            return """
            /ping — alive check
            /echo <text> — send text back
            /status — daemon info
            /user — known senders
            /help — this message
            """

        default:
            return "Unknown command: \(cmd)\nTry /help"
        }
    }

    // MARK: - Helpers

    static func loadOrCreateKeyPair() throws -> NostrKeyPair {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mCLIChat")
        let keyFile = dir.appendingPathComponent("swift_echo.key")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

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

    static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func formatUptime(since start: Date) -> String {
        let secs = Int(Date().timeIntervalSince(start))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

// MARK: - DaemonConfig

struct DaemonConfig {
    let name: String
    let about: String

    static func load(section: String) -> DaemonConfig {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mCLIChat/config.toml")
        if !FileManager.default.fileExists(atPath: configURL.path) {
            writeDefaultConfig(to: configURL)
        }
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return .defaults
        }
        return parse(content, section: section)
    }

    private static var defaults: DaemonConfig {
        DaemonConfig(
            name:  kVersion,
            about: "Swift Agent Daemon https://github.com/zehrer/mChat"
        )
    }

    private static func parse(_ content: String, section: String) -> DaemonConfig {
        var inSection = false
        var values: [String: String] = [:]
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inSection = (line == "[\(section)]")
                continue
            }
            guard inSection else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") {
                val = String(val.dropFirst().dropLast())
            }
            values[key] = val
        }
        return DaemonConfig(
            name:  values["name"]  ?? defaults.name,
            about: values["about"] ?? defaults.about
        )
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
