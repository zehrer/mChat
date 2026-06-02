import Foundation
import mChatCore

/// Thread-safe cache mapping pubkey hex → display name.
private actor NameCache {
    private var names: [String: String] = [:]

    func name(for pubkey: String) -> String? { names[pubkey] }
    func store(_ name: String, for pubkey: String) { names[pubkey] = name }
    func remove(for pubkey: String) { names.removeValue(forKey: pubkey) }
}

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

        let nameCache = NameCache()

        // Background task: print incoming messages as they arrive
        Task {
            for await msg in await backend.incomingMessages() {
                let pubkey = msg.senderIdentifier
                let display: String
                if let cached = await nameCache.name(for: pubkey) {
                    display = cached
                } else {
                    display = String(pubkey.prefix(12)) + "…"
                    // Fetch kind:0 in background; next message will show the name
                    Task {
                        if let contact = try? await backend.resolveContact(identifier: pubkey),
                           let name = contact.displayName {
                            await nameCache.store(name, for: pubkey)
                        }
                    }
                }
                print("\n[\(shortTime(msg.timestamp))] \(display): \(msg.content)")
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
                guard tokens.count == 2 else { print("Usage: chat <npub|pubkey>"); continue }
                activePeer = resolveHex(tokens[1])
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

    static func sendDM(_ text: String, to pubkeyOrNpub: String, via backend: NostrBackend) async {
        let hex = resolveHex(pubkeyOrNpub)
        let conv = Conversation(protocol: .nostr, type: .oneToOne(peerIdentifier: hex))
        do {
            _ = try await backend.send(text: text, in: conv)
            print("[sent]")
        } catch {
            print("Send failed: \(error)")
        }
    }

    /// Converts an npub1… bech32 string to lowercase hex. Returns the input unchanged if it
    /// is already hex or cannot be decoded.
    static func resolveHex(_ input: String) -> String {
        let s = input.lowercased()
        guard s.hasPrefix("npub1") else { return s }
        let data = s.dropFirst(5) // drop "npub1"
        guard let decoded = bech32Decode(String(data)) else { return s }
        return decoded.map { String(format: "%02x", $0) }.joined()
    }

    // Minimal bech32 decoder (no checksum verification — just data extraction).
    private static let bech32Charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    static func bech32Decode(_ dataStr: String) -> [UInt8]? {
        var values = [UInt8]()
        for c in dataStr {
            guard let idx = bech32Charset.firstIndex(of: c) else { return nil }
            values.append(UInt8(bech32Charset.distance(from: bech32Charset.startIndex, to: idx)))
        }
        // Drop last 6 characters (checksum)
        guard values.count > 6 else { return nil }
        let data = Array(values.dropLast(6))
        return convertBits(data, from: 5, to: 8, pad: false)
    }

    static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0; var bits = 0; var out = [UInt8](); let maxv = (1 << to) - 1
        for value in data {
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad { if bits > 0 { out.append(UInt8((acc << (to - bits)) & maxv)) } }
        else if bits >= from || ((acc << (to - bits)) & maxv) != 0 { return nil }
        return out
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
