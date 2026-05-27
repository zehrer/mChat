mod contacts;

use nostr_sdk::prelude::*;
use std::{
    fs,
    io::{self as stdio, Write},
    path::PathBuf,
    time::Duration,
};
use tokio::io::{AsyncBufReadExt, BufReader};

const DEFAULT_RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://relay.nostr.band",
    "wss://nos.lol",
    "wss://relay.snort.social",
    "wss://nostr.wine",
    "wss://relay.current.fyi",
    "wss://purplepag.es",
];

/// NIP-38 kind for user status events.
const KIND_STATUS: u16 = 30315;
/// Seconds before our "online" status expires.
const STATUS_TTL: u64 = 600; // 10 min

// MARK: - Identity

fn identity_path() -> PathBuf {
    let home = std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    home.join(".mCLIChat").join("identity.key")
}

fn load_or_create_keys() -> anyhow::Result<Keys> {
    let path = identity_path();
    if path.exists() {
        let hex = fs::read_to_string(&path)?.trim().to_string();
        if !hex.is_empty() {
            return Ok(Keys::parse(&hex)?);
        }
    }
    let keys = Keys::generate();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&path, keys.secret_key().to_secret_hex())?;
    println!("New identity generated — saved to {}", path.display());
    Ok(keys)
}

// MARK: - Alias resolution

/// Resolves a bare alias (`alice`, `@alice`) or pubkey (hex / npub) to a `PublicKey`.
fn resolve(arg: &str, book: &contacts::Contacts) -> anyhow::Result<PublicKey> {
    let key = arg.trim_start_matches('@');

    // 1. Try alias lookup
    if let Some(stored) = book.get(key) {
        return PublicKey::parse(stored)
            .map_err(|e| anyhow::anyhow!("Stored key for '{}' is invalid: {}", key, e));
    }

    // 2. Try direct pubkey (hex or bech32)
    PublicKey::parse(arg).map_err(|e| anyhow::anyhow!("Unknown alias or invalid pubkey '{}': {}", arg, e))
}

// MARK: - Sending

async fn send_dm(client: &Client, keys: &Keys, recipient: &PublicKey, text: &str) {
    // Explicit NIP-04 (kind:4) so every Nostr client can read and reply in kind.
    let encrypted = match nip04::encrypt(keys.secret_key(), recipient, text) {
        Ok(e) => e,
        Err(e) => { println!("Encrypt failed: {e}"); return; }
    };
    let builder = EventBuilder::new(
        Kind::EncryptedDirectMessage,
        encrypted,
        [Tag::public_key(*recipient)],
    );
    match client.send_event_builder(builder).await {
        Ok(_) => println!("[sent]"),
        Err(e) => println!("Send failed: {e}"),
    }
}

// MARK: - NIP-38 Presence

/// Publishes a `kind:30315` "online" status with a TTL expiration.
async fn publish_online_status(client: &Client) {
    let exp = Timestamp::from(Timestamp::now().as_u64() + STATUS_TTL);
    let builder = EventBuilder::new(
        Kind::Custom(KIND_STATUS),
        "online",
        [Tag::identifier("general"), Tag::expiration(exp)],
    );
    if let Err(e) = client.send_event_builder(builder).await {
        eprintln!("[warn] Could not publish online status: {e}");
    }
}

/// Returns a human-readable status string for a contact by checking their latest
/// `kind:30315` event. Expires = online; stale = last-seen duration; none = offline.
async fn fetch_status(client: &Client, pubkey: &PublicKey) -> String {
    let filter = Filter::new()
        .author(*pubkey)
        .kind(Kind::Custom(KIND_STATUS))
        .limit(1);

    let events = match client
        .fetch_events(vec![filter], Some(Duration::from_secs(3)))
        .await
    {
        Ok(ev) => ev,
        Err(_) => return "?".into(),
    };

    let Some(event) = events.first() else {
        return "offline".into();
    };

    let now = Timestamp::now().as_u64();

    // Check expiration tag first (NIP-38 proper)
    for tag in event.tags.iter() {
        if tag.kind() == TagKind::Expiration {
            if let Some(val) = tag.content() {
                if let Ok(exp_secs) = val.parse::<u64>() {
                    return if exp_secs > now {
                        "online".into()
                    } else {
                        human_duration(now.saturating_sub(exp_secs))
                    };
                }
            }
        }
    }

    // Fallback: use event timestamp
    let age = now.saturating_sub(event.created_at.as_u64());
    if age < STATUS_TTL {
        "online".into()
    } else {
        human_duration(age)
    }
}

fn human_duration(secs: u64) -> String {
    if secs < 3600 {
        format!("{}m ago", secs / 60)
    } else if secs < 86400 {
        format!("{}h ago", secs / 3600)
    } else {
        format!("{}d ago", secs / 86400)
    }
}

// MARK: - UI helpers

fn print_help() {
    println!(
        "\nCommands:\n  \
         whoami                    Show your public key / npub / private key\n  \
         chat <alias|npub|pubkey>  Set active chat partner (then just type to send)\n  \
         send <alias|npub|pubkey> <msg>  Send a one-off DM\n  \
         contacts                  List contacts with online status\n  \
         add <alias> <npub|pubkey> Add a contact\n  \
         remove <alias>            Remove a contact\n  \
         relays                    List connected relays\n  \
         help                      Show this help\n  \
         quit                      Disconnect and exit\n"
    );
}

fn format_time(ts: Timestamp) -> String {
    let secs = ts.as_u64();
    format!("{:02}:{:02}", (secs % 86400) / 3600, (secs % 3600) / 60)
}

fn print_msg(from_hex: &str, ts: Timestamp, content: &str, live: bool) {
    let from = if from_hex.len() >= 12 { &from_hex[..12] } else { from_hex };
    let time = format_time(ts);
    if live {
        print!("\r[{time}] {from}…: {content}\n> ");
    } else {
        print!("[{time}] {from}…: {content}\n");
    }
    stdio::stdout().flush().ok();
}

fn prompt() {
    print!("> ");
    stdio::stdout().flush().ok();
}

// MARK: - Main

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let keys = load_or_create_keys()?;
    println!("Your pubkey : {}", keys.public_key().to_hex());
    if let Ok(npub) = keys.public_key().to_bech32() {
        println!("Your npub   : {npub}");
    }

    let client = Client::new(keys.clone());
    for relay in DEFAULT_RELAYS {
        client.add_relay(*relay).await?;
    }

    println!("Connecting to Nostr relays…");
    client.connect().await;
    println!("Connected to {} relays.", DEFAULT_RELAYS.len());

    // Announce ourselves as online (NIP-38)
    publish_online_status(&client).await;
    println!("Status: online\n");

    // Must grab notification receiver BEFORE subscribing to avoid missing
    // events that the relay delivers before this receiver is created.
    let mut notifications = client.notifications();

    // Subscribe: NIP-04 (kind:4) and NIP-17 gift wraps (kind:1059) addressed to us
    let filter_nip04 = Filter::new()
        .pubkey(keys.public_key())
        .kind(Kind::EncryptedDirectMessage)
        .limit(50);
    let filter_nip17 = Filter::new()
        .pubkey(keys.public_key())
        .kind(Kind::GiftWrap)
        .limit(50);
    client.subscribe(vec![filter_nip04, filter_nip17], None).await?;

    let sk = keys.secret_key().to_owned();
    let client_clone = client.clone();
    tokio::spawn(async move {
        let mut history_done = false;
        while let Ok(notification) = notifications.recv().await {
            match notification {
                RelayPoolNotification::Event { event, .. } => {
                    if event.kind == Kind::EncryptedDirectMessage {
                        // NIP-04
                        if let Ok(content) = nip04::decrypt(&sk, &event.pubkey, &event.content) {
                            print_msg(&event.pubkey.to_hex(), event.created_at, &content, history_done);
                        }
                    } else if event.kind == Kind::GiftWrap {
                        // NIP-17 — unwrap gift, extract rumor content
                        if let Ok(unwrapped) = client_clone.unwrap_gift_wrap(&event).await {
                            let content = unwrapped.rumor.content.clone();
                            let sender = unwrapped.sender.to_hex();
                            let ts = unwrapped.rumor.created_at;
                            print_msg(&sender, ts, &content, history_done);
                        }
                    }
                }
                RelayPoolNotification::Message { message, .. } => {
                    if let RelayMessage::EndOfStoredEvents(_) = message {
                        if !history_done {
                            history_done = true;
                            println!("─── live ───");
                            prompt();
                        }
                    }
                }
                _ => {}
            }
        }
    });

    print_help();
    prompt();

    let stdin = BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();
    let mut active_peer: Option<PublicKey> = None;
    let mut book = contacts::load();

    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim().to_string();
        if line.is_empty() {
            prompt();
            continue;
        }

        let mut parts = line.splitn(3, ' ');
        let cmd = parts.next().unwrap_or("").to_lowercase();
        let arg1 = parts.next().unwrap_or("").trim().to_string();
        let rest = parts.next().unwrap_or("").trim().to_string();

        match cmd.as_str() {
            "help" => print_help(),

            "whoami" => {
                println!("Public key : {}", keys.public_key().to_hex());
                if let Ok(npub) = keys.public_key().to_bech32() {
                    println!("npub       : {npub}");
                }
                println!("Private key: {}  ← keep secret", keys.secret_key().to_secret_hex());
            }

            "contacts" | "list" => {
                if book.is_empty() {
                    println!("No contacts yet. Use: add <alias> <npub|pubkey>");
                } else {
                    println!("Contacts:");
                    let entries: Vec<_> = book.iter().collect();
                    for (alias, pubkey_str) in &entries {
                        let display = if pubkey_str.len() > 20 {
                            format!("{}…", &pubkey_str[..20])
                        } else {
                            pubkey_str.to_string()
                        };
                        if let Ok(pk) = PublicKey::parse(pubkey_str) {
                            let status = fetch_status(&client, &pk).await;
                            println!("  {:<16}  {}  [{}]", alias, display, status);
                        } else {
                            println!("  {:<16}  {}  [invalid key]", alias, display);
                        }
                    }
                }
            }

            "add" => {
                if arg1.is_empty() || rest.is_empty() {
                    println!("Usage: add <alias> <npub or pubkey hex>");
                } else {
                    match PublicKey::parse(&rest) {
                        Ok(_) => {
                            book.insert(arg1.clone(), rest.clone());
                            if let Err(e) = contacts::save(&book) {
                                println!("Save failed: {e}");
                            } else {
                                println!("Added: {} → {}", arg1, rest);
                            }
                        }
                        Err(_) => println!("Invalid pubkey: {rest}"),
                    }
                }
            }

            "remove" => {
                if arg1.is_empty() {
                    println!("Usage: remove <alias>");
                } else if book.remove(&arg1).is_some() {
                    contacts::save(&book).ok();
                    println!("Removed: {arg1}");
                } else {
                    println!("No contact named '{arg1}'");
                }
            }

            "relays" => {
                let relays = client.relays().await;
                for url in relays.keys() {
                    println!("  {url}");
                }
                println!("  ({} relays)", relays.len());
            }

            "chat" => {
                if arg1.is_empty() {
                    println!("Usage: chat <alias | npub | pubkey>");
                } else {
                    match resolve(&arg1, &book) {
                        Ok(pk) => {
                            println!("Chatting with {arg1}");
                            println!("Just type a message and press Enter to send.");
                            active_peer = Some(pk);
                        }
                        Err(e) => println!("{e}"),
                    }
                }
            }

            "send" => {
                if arg1.is_empty() || rest.is_empty() {
                    println!("Usage: send <alias | npub | pubkey> <message>");
                } else {
                    match resolve(&arg1, &book) {
                        Ok(pk) => send_dm(&client, &keys, &pk, &rest).await,
                        Err(e) => println!("{e}"),
                    }
                }
            }

            "quit" | "exit" | "q" => {
                println!("Disconnecting…");
                client.disconnect().await?;
                break;
            }

            _ => {
                if let Some(peer) = &active_peer {
                    send_dm(&client, &keys, peer, &line).await;
                } else {
                    println!("Unknown command. Type 'help' for commands.");
                }
            }
        }

        prompt();
    }

    Ok(())
}
