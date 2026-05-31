import Foundation
import Glibc
import mChatCore

@main
struct EchoDaemon {
    static func main() async {
        setbuf(stdout, nil)  // unbuffer so log lines flush immediately when piped
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

        for await msg in await backend.incomingMessages() {
            guard !msg.fromMe else { continue }
            let from = String(msg.senderIdentifier.prefix(12))
            print("[\(shortTime(msg.timestamp))] \(from)…: \(msg.content)")

            let reply = "echo: \(msg.content)"
            let conv = Conversation(
                protocol: .nostr,
                type: .oneToOne(peerIdentifier: msg.senderIdentifier)
            )
            do {
                _ = try await backend.send(text: reply, in: conv)
                print("  → echoed")
            } catch {
                print("  → send failed: \(error)")
            }
        }
    }

    // MARK: - Identity

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
}

// MARK: - DaemonConfig

/// Reads daemon configuration from ~/.mCLIChat/config.toml.
/// Falls back to built-in defaults when the file is absent or a key is missing.
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
            name:  "mSwiftChatd v0.0.1",
            about: "Swift echo daemon — replies with 'echo: <message>' https://github.com/zehrer/mChat"
        )
    }

    // Minimal TOML parser: flat key = "value" within named [sections]
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
        # Edit to customise the daemon profiles. Restart the daemon after changes.

        [swift]
        name  = "mSwiftChatd v0.0.1"
        about = "Swift echo daemon — replies with 'echo: <message>' https://github.com/zehrer/mChat"

        [rust]
        name  = "mRustChatd v0.0.1"
        about = "Rust echo daemon — replies with 'echo: <message>' https://github.com/zehrer/mChat"
        """
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
