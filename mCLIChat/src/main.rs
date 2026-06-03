mod contacts;

use nostr_sdk::prelude::*;
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::{self as stdio, Write},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    sync::RwLock,
    time::{timeout, Instant},
};

type NameCache = Arc<RwLock<HashMap<String, String>>>;

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

fn mclichat_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("MCLICHAT_DIR") {
        return PathBuf::from(dir);
    }
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(".mCLIChat")
}

fn identity_path() -> PathBuf { mclichat_dir().join("identity.key") }
fn pre_seen_path() -> PathBuf  { mclichat_dir().join("pre_seen.txt") }

fn load_pre_seen() -> HashSet<EventId> {
    fs::read_to_string(pre_seen_path()).unwrap_or_default()
        .lines()
        .filter_map(|l| EventId::from_hex(l.trim()).ok())
        .collect()
}

fn save_pre_seen(seen: &HashSet<EventId>) {
    const MAX: usize = 20_000;
    let data: String = seen.iter().take(MAX).map(|id| id.to_hex()).collect::<Vec<_>>().join("\n");
    let _ = fs::write(pre_seen_path(), data);
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
    eprintln!("New identity generated — saved to {}", path.display());
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
        Ok(_) => eprintln!("[sent]"),
        Err(e) => eprintln!("Send failed: {e}"),
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

fn print_msg(display: &str, ts: Timestamp, content: &str, live: bool) {
    let time = format_time(ts);
    if live {
        print!("\r[{time}] {display}: {content}\n> ");
    } else {
        print!("[{time}] {display}: {content}\n");
    }
    stdio::stdout().flush().ok();
}

/// Fetches the Nostr display name (kind:0) for a pubkey. Returns None if unavailable.
async fn fetch_name(client: &Client, pubkey: &PublicKey) -> Option<String> {
    let filter = Filter::new().author(*pubkey).kind(Kind::Metadata).limit(1);
    let events = client
        .fetch_events(vec![filter], Some(Duration::from_secs(3)))
        .await
        .ok()?;
    let event = events.first()?;
    let meta: serde_json::Value = serde_json::from_str(&event.content).ok()?;
    meta.get("display_name")
        .or_else(|| meta.get("name"))
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// Returns a display name from the cache. If not cached, triggers a background
/// fetch and returns a truncated pubkey hex in the meantime.
async fn cached_name(pubkey_hex: &str, cache: &NameCache, client: &Client) -> String {
    if let Some(name) = cache.read().await.get(pubkey_hex) {
        return name.clone();
    }
    let hex = pubkey_hex.to_string();
    let cache = cache.clone();
    let client = client.clone();
    tokio::spawn(async move {
        if let Ok(pk) = PublicKey::parse(&hex) {
            if let Some(name) = fetch_name(&client, &pk).await {
                cache.write().await.insert(hex, name);
            }
        }
    });
    format!("{}…", &pubkey_hex[..12.min(pubkey_hex.len())])
}

fn prompt() {
    print!("> ");
    stdio::stdout().flush().ok();
}

// MARK: - Send mode (non-interactive, for scripting / integration tests)

// Usage: mCLIChat --send [--timeout <secs>] <npub|pubkey> <message...>
// Sends one message, waits for a reply, prints it to stdout, exits.
// All status output goes to stderr so stdout carries only the reply.
async fn run_send_mode(args: &[String]) -> anyhow::Result<()> {
    let mut args = args.iter().peekable();

    // Optional --timeout flag
    let mut reply_timeout_secs: u64 = 30;
    if args.peek().map(|s| s.as_str()) == Some("--timeout") {
        args.next();
        reply_timeout_secs = args.next()
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| anyhow::anyhow!("--timeout requires a number"))?;
    }

    let target_str = args.next().ok_or_else(|| anyhow::anyhow!("Usage: --send [--timeout N] <npub|pubkey> <message>"))?;
    let message_parts: Vec<&String> = args.collect();
    if message_parts.is_empty() {
        anyhow::bail!("Usage: --send [--timeout N] <npub|pubkey> <message>");
    }
    let message = message_parts.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(" ");

    let target = PublicKey::parse(target_str)
        .map_err(|e| anyhow::anyhow!("Invalid target pubkey '{}': {}", target_str, e))?;

    let keys = load_or_create_keys()?;
    let client = Client::new(keys.clone());
    for relay in DEFAULT_RELAYS { client.add_relay(*relay).await?; }

    eprintln!("Connecting to relays…");
    client.connect().await;

    // Grab notifications before subscribing to avoid missing events.
    let mut notifications = client.notifications();

    // Subscribe for DMs addressed to us — no time filter, we rely on EOSE.
    client.subscribe(vec![
        Filter::new().pubkey(keys.public_key()).kind(Kind::GiftWrap),
        Filter::new().pubkey(keys.public_key()).kind(Kind::EncryptedDirectMessage),
    ], None).await?;

    // Wait for EOSE from all connected relays (up to 8s total) and collect
    // every event into pre_seen. We wait for all relays to EOSE so every
    // stored event from every relay is captured before we send.
    let relay_count = client.relays().await.len().max(1);
    // Seed pre_seen from disk so events seen in previous runs are also skipped.
    let mut pre_seen: HashSet<EventId> = load_pre_seen();
    let eose_deadline = Instant::now() + Duration::from_secs(8);
    let mut eose_count = 0;
    loop {
        let remaining = eose_deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            eprintln!("(EOSE timeout: {eose_count}/{relay_count} relays responded — sending anyway)");
            break;
        }
        match timeout(remaining, notifications.recv()).await {
            Ok(Ok(RelayPoolNotification::Event { event, .. })) => {
                pre_seen.insert(event.id);
            }
            Ok(Ok(RelayPoolNotification::Message { message: msg, .. })) => {
                if let RelayMessage::EndOfStoredEvents(_) = msg {
                    eose_count += 1;
                    if eose_count >= relay_count { break; }
                }
            }
            Ok(Err(_)) | Err(_) => break,
            _ => {}
        }
    }

    // Quiet-period drain: keep reading until 500 ms of silence or 5 s cap.
    // Slow relays may deliver stored events slightly after their EOSE; this
    // ensures all of them land in pre_seen before we send the command.
    let drain_cap = Instant::now() + Duration::from_secs(5);
    let mut last_activity = Instant::now();
    loop {
        let quiet_remaining = Duration::from_millis(500)
            .saturating_sub(last_activity.elapsed());
        let cap_remaining = drain_cap.saturating_duration_since(Instant::now());
        let wait = quiet_remaining.min(cap_remaining);
        if wait.is_zero() { break; }
        match timeout(wait, notifications.recv()).await {
            Ok(Ok(RelayPoolNotification::Event { event, .. })) => {
                pre_seen.insert(event.id);
                last_activity = Instant::now();
            }
            _ => {}
        }
    }

    // Send the message (NIP-04; daemon accepts both NIP-04 and NIP-17).
    eprintln!("Sending: {message}");
    let send_time = Timestamp::now();
    send_dm(&client, &keys, &target, &message).await;
    eprintln!("Waiting for reply ({reply_timeout_secs}s timeout)…");

    // Wait for the first reply from the target. Every event received here is
    // added to pre_seen so future --send invocations skip it automatically.
    //
    // Stale-reply guard: the daemon reuses its identity key across restarts, so
    // old relay-stored replies from a previous binary (same pubkey, stale content)
    // could pass the sender check. Reject any reply whose inner rumor created_at
    // is more than 120 s before we sent — clock-skew safe but rejects day-old events.
    let reply_deadline = Instant::now() + Duration::from_secs(reply_timeout_secs);
    loop {
        let remaining = reply_deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            save_pre_seen(&pre_seen);
            eprintln!("Timeout: no reply received within {reply_timeout_secs}s.");
            std::process::exit(1);
        }
        match timeout(remaining, notifications.recv()).await {
            Ok(Ok(RelayPoolNotification::Event { event, .. })) => {
                if !pre_seen.insert(event.id) { continue; }  // skip if already seen
                if event.kind == Kind::GiftWrap {
                    if let Ok(unwrapped) = client.unwrap_gift_wrap(&event).await {
                        if unwrapped.sender == target {
                            let rumor_ts = unwrapped.rumor.created_at.as_u64();
                            let send_ts  = send_time.as_u64();
                            if rumor_ts + 120 < send_ts {
                                eprintln!("(skipping stale gift-wrap reply: rumor ts {}s old)", send_ts.saturating_sub(rumor_ts));
                                continue;
                            }
                            save_pre_seen(&pre_seen);
                            println!("{}", unwrapped.rumor.content);
                            return Ok(());
                        }
                    }
                } else if event.kind == Kind::EncryptedDirectMessage && event.pubkey == target {
                    if event.created_at.as_u64() + 120 < send_time.as_u64() {
                        eprintln!("(skipping stale NIP-04 reply: {}s old)", send_time.as_u64().saturating_sub(event.created_at.as_u64()));
                        continue;
                    }
                    if let Ok(content) = nip04::decrypt(keys.secret_key(), &event.pubkey, &event.content) {
                        save_pre_seen(&pre_seen);
                        println!("{content}");
                        return Ok(());
                    }
                }
            }
            Ok(Err(_)) | Err(_) => continue,
            _ => {}
        }
    }
}

// MARK: - Main

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli_args: Vec<String> = std::env::args().skip(1).collect();
    match cli_args.first().map(|s| s.as_str()) {
        // --whoami: print pubkey hex to stdout and exit (used by test scripts)
        Some("--whoami") => {
            let keys = load_or_create_keys()?;
            println!("{}", keys.public_key().to_hex());
            return Ok(());
        }
        // --send: non-interactive send mode for scripting / integration tests
        Some("--send") => return run_send_mode(&cli_args[1..]).await,
        _ => {}
    }

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

    // Name cache: pubkey hex → display name. Pre-seeded from contact aliases.
    let name_cache: NameCache = Arc::new(RwLock::new(HashMap::new()));
    {
        let book = contacts::load();
        let mut lock = name_cache.write().await;
        for (alias, pubkey_str) in &book {
            if let Ok(pk) = PublicKey::parse(pubkey_str) {
                lock.insert(pk.to_hex(), alias.clone());
            }
        }
    }

    let sk = keys.secret_key().to_owned();
    let client_clone = client.clone();
    let cache_clone = name_cache.clone();
    tokio::spawn(async move {
        let mut seen: std::collections::HashSet<EventId> = std::collections::HashSet::new();
        let mut history_done = false;
        while let Ok(notification) = notifications.recv().await {
            match notification {
                RelayPoolNotification::Event { event, .. } => {
                    if !seen.insert(event.id) { continue; }
                    if event.kind == Kind::EncryptedDirectMessage {
                        // NIP-04
                        if let Ok(content) = nip04::decrypt(&sk, &event.pubkey, &event.content) {
                            let display = cached_name(&event.pubkey.to_hex(), &cache_clone, &client_clone).await;
                            print_msg(&display, event.created_at, &content, history_done);
                        }
                    } else if event.kind == Kind::GiftWrap {
                        // NIP-17 — unwrap gift, extract rumor content
                        if let Ok(unwrapped) = client_clone.unwrap_gift_wrap(&event).await {
                            let content = unwrapped.rumor.content.clone();
                            let sender = unwrapped.sender.to_hex();
                            let ts = unwrapped.rumor.created_at;
                            let display = cached_name(&sender, &cache_clone, &client_clone).await;
                            print_msg(&display, ts, &content, history_done);
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
                        Ok(pk) => {
                            book.insert(arg1.clone(), rest.clone());
                            name_cache.write().await.insert(pk.to_hex(), arg1.clone());
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
                } else if let Some(pubkey_str) = book.remove(&arg1) {
                    if let Ok(pk) = PublicKey::parse(&pubkey_str) {
                        name_cache.write().await.remove(&pk.to_hex());
                    }
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
