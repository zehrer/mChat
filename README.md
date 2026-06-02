# mChat

**A native, open, privacy-first iOS chat app — your WhatsApp replacement that shares nothing with anyone.**

mChat is built on open protocols and cryptographic identities. No phone number. No central server. No company reading your messages. Your private key never leaves your device.

---

## Why mChat?

| WhatsApp | mChat |
|---|---|
| Phone number required | Keypair — no registration |
| Meta reads metadata | End-to-end encrypted content + sealed sender (NIP-17) |
| One company controls the server | Dozens of independent relay operators |
| Closed source | Fully open source (MIT) |
| Contact list uploaded to Meta | Contacts stay on your device |

---

## Components

### mChat — iOS App *(in development)*

SwiftUI app targeting iOS 17+. Uses **NostrEssentials** (`nostur-com/NostrEssentials`) as the Nostr protocol layer — no duplicate implementation.

### mChatd — Rust Daemon

Always-on agent daemon for HomeNode integration. Receives encrypted DMs (NIP-17/NIP-04), applies access control, responds to commands. Written in Rust using `nostr-sdk`.

### mCLIChat — Rust CLI Client

Interactive Nostr chat client. Doubles as an integration test tool for mChatd — connects with a separate keypair and can script command/response sequences.

---

## Architecture

```
┌─────────────────────────────────────────┐
│           iOS App (SwiftUI)             │
│  Onboarding · Conversations · Chat      │
└──────────────────┬──────────────────────┘
                   │ NostrEssentials
                   │ (nostur-com/NostrEssentials)
                   ▼
            Nostr Relay Network
                   ▲
                   │ nostr-sdk (Rust)
┌──────────────────┴──────────────────────┐
│              mChatd (Rust)              │
│  Access control · Commands · NIP-17     │
└─────────────────────────────────────────┘
```

---

## Project Layout

```
mChat/
├── Cargo.toml              # Rust workspace
├── Cargo.lock
├── Makefile
├── mChatd/                 # Rust daemon
│   ├── Cargo.toml
│   └── src/main.rs
├── mCLIChat/               # Rust CLI client / integration test tool
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs
│       └── contacts.rs
├── mChat/                  # iOS app (Xcode project, uses NostrEssentials)
│   ├── App/
│   ├── Views/
│   ├── Services/
│   └── Storage/
├── Archive/                # Retired Swift implementations (kept for reference)
│   ├── mSwiftChatd/
│   ├── mSwiftCLIChat/
│   ├── mChatCore/
│   └── mChatCoreTests/
└── docs/
    ├── SDP.md              # Software Development Plan
    ├── TEST_PLAN_REMOTE.md # Remote verification test plan
    └── ...
```

---

## Getting Started

### mChatd (Daemon)

**Prerequisites:** Rust 1.x + Cargo (`rustup`)

```bash
make build-release   # build
make deploy          # build + restart daemon
make test            # run unit tests (33 tests)
make status          # check if running
make logs            # tail the log
```

Data files are stored in `~/.mCLIChat/`. On first run a keypair is generated at `~/.mCLIChat/mchatd.key`.

Configure the daemon profile in `~/.mCLIChat/config.toml`:
```toml
[rust]
name  = "mChatd v0.0.2"
about = "Rust Agent Daemon https://github.com/zehrer/mChat"
```

Grant admin access by editing `~/.mCLIChat/roles.json`:
```json
{ "YOUR_HEX_PUBKEY": "admin" }
```

### mCLIChat (CLI Client)

```bash
cargo run -p mCLIChat    # launch interactive CLI
```

Commands: `chat <alias|npub>`, `send <alias> <msg>`, `contacts`, `add`, `remove`, `whoami`, `help`

### mChat (iOS App)

iOS app development is in progress. See `mChat/` for current SwiftUI sources.

---

## Daemon Commands

| Command | Description |
|---|---|
| `/p(ing)` | Alive check → `pong` |
| `/s(tatus)` | Version, uptime, relay list, message counts |
| `/u(ser)` | Sender list with ID, access state, role |
| `/user det(ails) <id>` | Full profile re-fetched from relays |
| `/user auth(orize) <id>` | Grant access and notify user |
| `/user bl(ock) <id>` | Block user and notify them *(admin only)* |
| `/user del(ete) <id>` | Remove from all lists *(admin only)* |
| `/h(elp)` | Command list + your current role |

Shortcuts: `/p` = `/ping`, `/s` = `/status`, `/h` = `/help`, `/u` = `/user`, `/u bl 3` = `/user block 3`, etc.

---

## Roadmap

| Phase | Status | What's included |
|---|---|---|
| **Daemon v0.0.2** | ✅ Done | NIP-17/NIP-04 reception, access control, roles, user registry, command shortcuts, admin notifications |
| **Daemon v0.1.0** | 🔜 Next | Auto-reconnect on relay drop (REQ-50–54), mCLIChat integration tests |
| **iOS App MVP** | 🔜 Next | NostrEssentials integration, 1:1 NIP-17 messaging, identity onboarding |
| **iOS App v1.0** | 📅 Planned | NIP-44 encryption, group chat (NIP-28), contacts integration, SwiftData persistence |
| **HomeNode integration** | 📅 Planned | mChatd embedded as agent backend |

---

## Privacy Principles

1. **Private key never leaves your device** — stored in iOS Keychain / local file, never transmitted
2. **No phone number, no email, no registration** — identity is a cryptographic keypair
3. **No contact list uploaded** — address book integration is fully on-device
4. **No telemetry** — zero analytics
5. **Open source** — every line is auditable

---

## Documentation

| Document | Description |
|---|---|
| [docs/SDP.md](docs/SDP.md) | Software Development Plan — architecture, requirements, test plan |
| [docs/TEST_PLAN_REMOTE.md](docs/TEST_PLAN_REMOTE.md) | Remote verification test plan for mChatd |
| [REQUIREMENTS.md](REQUIREMENTS.md) | Full functional and non-functional requirements |
| [SETUP.md](SETUP.md) | Setup guide |

---

## Contributing

Issues and pull requests are welcome. See [REQUIREMENTS.md](REQUIREMENTS.md) for the current scope.

---

## License

MIT — see [LICENSE](LICENSE).
