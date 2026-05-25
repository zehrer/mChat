import Foundation
import mChatCore

@main
struct CLIApp {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("Fatal error: \(error)\n", stderr)
            exit(1)
        }
    }

    // MARK: - Main loop

    static func run() async throws {
        let keyPair = try loadOrCreateKeyPair()
        print("Your pubkey : \(keyPair.publicKeyHex)")

        let backend = NostrBackend(keyPair: keyPair)
        print("Connecting to Nostr relays…")
        try await backend.connect()
        print("Connected.\n")

        // Background task: print incoming messages as they arrive
        Task {
            for await msg in await backend.incomingMessages() {
                let from = String(msg.senderIdentifier.prefix(12))
                print("\n[\(shortTime(msg.timestamp))] \(from)…: \(msg.content)")
                printPrompt()
            }
        }

        printHelp()

        var activePeer: String? = nil

        loop: while true {
            printPrompt()
            guard let line = readLine(strippingNewline: true)?
                    .trimmingCharacters(in: .whitespaces),
                  !line.isEmpty else { continue }

            // Split into at most 3 tokens: command, arg1, rest
            let tokens = line.split(separator: " ", maxSplits: 2,
                                    omittingEmptySubsequences: true).map(String.init)

            switch tokens[0].lowercased() {

            case "help":
                printHelp()

            case "whoami":
                print("Public key : \(keyPair.publicKeyHex)")
                print("Private key: \(keyPair.privateKeyHex)  ← keep secret")

            case "chat":
                guard tokens.count == 2 else { print("Usage: chat <pubkey>"); continue }
                activePeer = tokens[1]
                print("Chatting with \(activePeer!)")
                print("Just type a message and press Enter to send.")

            case "send":
                guard tokens.count == 3 else { print("Usage: send <pubkey> <message>"); continue }
                await sendDM(tokens[2], to: tokens[1], via: backend)

            case "quit", "exit", "q":
                print("Disconnecting…")
                await backend.disconnect()
                break loop

            default:
                if let peer = activePeer {
                    await sendDM(line, to: peer, via: backend)
                } else {
                    print("Unknown command. Type 'help' for commands.")
                }
            }
        }
    }

    // MARK: - Helpers

    static func sendDM(_ text: String, to pubkey: String, via backend: NostrBackend) async {
        let conv = Conversation(protocol: .nostr, type: .oneToOne(peerIdentifier: pubkey))
        do {
            _ = try await backend.send(text: text, in: conv)
            print("[sent]")
        } catch {
            print("Send failed: \(error)")
        }
    }

    static func printPrompt() {
        print("> ", terminator: "")
        fflush(stdout)
    }

    static func printHelp() {
        print("""
        Commands:
          whoami               Show your public / private key
          chat <pubkey>        Set active chat partner (then just type to send)
          send <pubkey> <msg>  Send a one-off DM
          help                 Show this help
          quit                 Disconnect and exit
        """)
    }

    static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    // MARK: - Identity

    static func loadOrCreateKeyPair() throws -> NostrKeyPair {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mCLIChat")
        let keyFile = dir.appendingPathComponent("identity.key")

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: keyFile.path),
           let hex = try? String(contentsOf: keyFile, encoding: .utf8)
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !hex.isEmpty {
            return try NostrKeyPair(privateKeyHex: hex)
        }

        let kp = try NostrKeyPair()
        try kp.privateKeyHex.write(to: keyFile, atomically: true, encoding: .utf8)
        print("New identity generated — saved to \(keyFile.path)")
        return kp
    }
}
