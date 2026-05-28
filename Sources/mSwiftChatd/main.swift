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
        try await backend.publishProfile(name: "mSwiftChatd", about: "Swift echo daemon — replies with 'echo: <message>'")
        print("Profile published.")
        print("Connected. Listening for DMs…\n")

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
