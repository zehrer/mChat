use nostr_sdk::prelude::*;
use std::{collections::{HashMap, HashSet}, fs, path::PathBuf, time::Instant};

const VERSION: &str = "mRustChatd v0.0.2";
const SPAM_THRESHOLD: u32 = 5;

// MARK: - Paths

fn mclichat_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(".mCLIChat")
}

fn config_path()    -> PathBuf { mclichat_dir().join("config.toml") }
fn key_path()       -> PathBuf { mclichat_dir().join("mchatd.key") }
fn whitelist_path() -> PathBuf { mclichat_dir().join("whitelist.txt") }
fn blocked_path()   -> PathBuf { mclichat_dir().join("blocked.txt") }
fn pending_path()   -> PathBuf { mclichat_dir().join("pending.json") }

// MARK: - Config

#[derive(serde::Deserialize, Default)]
struct Config { rust: Option<ProfileConfig> }

#[derive(serde::Deserialize)]
struct ProfileConfig { name: Option<String>, about: Option<String> }

fn load_profile() -> (String, String) {
    let defaults = (
        VERSION.to_string(),
        "Rust Agent Daemon https://github.com/zehrer/mChat".to_string(),
    );
    let content = match fs::read_to_string(config_path()) { Ok(c) => c, Err(_) => return defaults };
    let config: Config = match toml::from_str(&content) { Ok(c) => c, Err(_) => return defaults };
    match config.rust {
        Some(p) => (p.name.unwrap_or(defaults.0), p.about.unwrap_or(defaults.1)),
        None => defaults,
    }
}

// MARK: - Keys

fn load_or_create_keys() -> anyhow::Result<Keys> {
    let path = key_path();
    if path.exists() {
        if let Ok(hex) = fs::read_to_string(&path) {
            if let Ok(keys) = Keys::parse(hex.trim()) { return Ok(keys); }
        }
    }
    let keys = Keys::generate();
    fs::create_dir_all(mclichat_dir())?;
    fs::write(&path, keys.secret_key().to_secret_hex())?;
    println!("Generated new identity → {}", path.display());
    Ok(keys)
}

// MARK: - Access control

enum Access { Authorized, Pending(u32), Blocked, New }

fn load_pubkey_file(path: &PathBuf) -> HashSet<String> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(String::from)
        .collect()
}

fn append_pubkey(path: &PathBuf, pubkey: &str) {
    let existing = fs::read_to_string(path).unwrap_or_default();
    let sep = if existing.ends_with('\n') || existing.is_empty() { "" } else { "\n" };
    let _ = fs::write(path, format!("{existing}{sep}{pubkey}\n"));
}

fn load_pending() -> HashMap<String, u32> {
    serde_json::from_str(&fs::read_to_string(pending_path()).unwrap_or_default())
        .unwrap_or_default()
}

fn save_pending(pending: &HashMap<String, u32>) {
    if let Ok(json) = serde_json::to_string_pretty(pending) {
        let _ = fs::write(pending_path(), json);
    }
}

fn check_access(pubkey: &str) -> Access {
    if load_pubkey_file(&whitelist_path()).contains(pubkey) { return Access::Authorized; }
    if load_pubkey_file(&blocked_path()).contains(pubkey)   { return Access::Blocked; }
    match load_pending().get(pubkey).copied() {
        Some(n) => Access::Pending(n),
        None    => Access::New,
    }
}

fn ensure_whitelist() {
    let path = whitelist_path();
    if !path.exists() {
        let _ = fs::write(&path,
            "# mRustChatd authorized pubkeys\n\
             # Add one hex pubkey per line to grant full access.\n\
             # Lines starting with # are ignored.\n"
        );
    }
}

// MARK: - Commands

fn handle_command(text: &str, start_time: &Instant, msg_count: u64, known_senders: &HashSet<String>) -> String {
    let (cmd, args) = text.split_once(' ')
        .map(|(c, a)| (c, a.trim()))
        .unwrap_or((text, ""));

    match cmd {
        "/ping" => "pong".to_string(),

        "/echo" => if args.is_empty() { "(empty)".to_string() } else { args.to_string() },

        "/status" => {
            let uptime = format_uptime(start_time.elapsed());
            let relays = DEFAULT_RELAYS.join(", ");
            let authorized = load_pubkey_file(&whitelist_path()).len();
            let pending = load_pending().len();
            let blocked = load_pubkey_file(&blocked_path()).len();
            format!(
                "{VERSION}\nUptime: {uptime}\nRelays ({n}): {relays}\n\
                 Messages: {msg_count}\nKnown senders: {senders}\n\
                 Authorized: {authorized} | Pending: {pending} | Blocked: {blocked}",
                n = DEFAULT_RELAYS.len(),
                senders = known_senders.len(),
            )
        }

        "/user" => {
            let authorized = load_pubkey_file(&whitelist_path());
            let pending = load_pending();
            let blocked = load_pubkey_file(&blocked_path());
            let mut lines = vec![];
            for pk in &authorized { lines.push(format!("[auth]    {}", shorten(pk))); }
            for (pk, n) in &pending { lines.push(format!("[pending] {} ({n}/{SPAM_THRESHOLD})", shorten(pk))); }
            for pk in &blocked  { lines.push(format!("[blocked] {}", shorten(pk))); }
            if lines.is_empty() { "No senders yet.".to_string() }
            else { lines.join("\n") }
        }

        "/help" => "/ping — alive check\n\
                    /echo <text> — send text back\n\
                    /status — daemon info\n\
                    /user — sender list with access state\n\
                    /help — this message".to_string(),

        _ => format!("Unknown command: {cmd}\nTry /help"),
    }
}

fn format_uptime(d: std::time::Duration) -> String {
    let s = d.as_secs();
    let (h, m, s) = (s / 3600, (s % 3600) / 60, s % 60);
    if h > 0 { format!("{h}h {m}m {s}s") }
    else if m > 0 { format!("{m}m {s}s") }
    else { format!("{s}s") }
}

fn dispatch(text: &str, start_time: &Instant, msg_count: u64, known_senders: &HashSet<String>) -> String {
    if text.starts_with('/') { handle_command(text, start_time, msg_count, known_senders) }
    else { format!("echo: {text}") }
}

// MARK: - Relays

const DEFAULT_RELAYS: &[&str] = &[
    "wss://nos.lol",
    "wss://relay.damus.io",
    "wss://relay.primal.net",
];

// MARK: - Main

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    fs::create_dir_all(mclichat_dir())?;
    ensure_whitelist();

    let keys = load_or_create_keys()?;
    println!("mRustChatd pubkey : {}", keys.public_key().to_hex());
    println!("mRustChatd npub   : {}", keys.public_key().to_bech32()?);

    let client = Client::new(keys.clone());
    for url in DEFAULT_RELAYS { client.add_relay(*url).await?; }
    client.connect().await;
    println!("Connected to {} relays.", DEFAULT_RELAYS.len());

    let mut notifications = client.notifications();
    client.subscribe(vec![
        Filter::new().pubkey(keys.public_key()).kind(Kind::EncryptedDirectMessage),
        Filter::new().pubkey(keys.public_key()).kind(Kind::GiftWrap),
    ], None).await?;

    let (profile_name, profile_about) = load_profile();
    publish_profile(&client, &profile_name, &profile_about).await;
    publish_relay_list(&client, DEFAULT_RELAYS).await;
    publish_dm_relay_list(&client, DEFAULT_RELAYS).await;
    println!("Listening for DMs… Ctrl+C to stop.\n");

    let start_time = Instant::now();
    let mut msg_count: u64 = 0;
    let mut seen: HashSet<EventId> = HashSet::new();
    let mut known_senders: HashSet<String> = HashSet::new();

    while let Ok(notification) = notifications.recv().await {
        let RelayPoolNotification::Event { event, .. } = notification else { continue };
        if !seen.insert(event.id) { continue; }

        let (sender_pubkey, sender_hex, content) = match event.kind {
            Kind::EncryptedDirectMessage => {
                let Ok(plain) = nip04::decrypt(keys.secret_key(), &event.pubkey, &event.content)
                else { continue };
                (event.pubkey, event.pubkey.to_hex(), plain)
            }
            Kind::GiftWrap => {
                let Ok(unwrapped) = client.unwrap_gift_wrap(&event).await else { continue };
                let inner = unwrapped.rumor;
                (inner.pubkey, inner.pubkey.to_hex(), inner.content)
            }
            _ => continue,
        };

        let from = shorten(&sender_hex);
        let proto = if event.kind == Kind::GiftWrap { "NIP-17" } else { "NIP-04" };

        match check_access(&sender_hex) {
            Access::Authorized => {
                known_senders.insert(sender_hex.clone());
                msg_count += 1;
                println!("[{proto}][auth] {from}: {content}");
                let reply = dispatch(&content, &start_time, msg_count, &known_senders);
                send_reply(&client, sender_pubkey, &reply).await;
            }

            Access::Blocked => {
                println!("[{proto}][blocked] {from}: ignored");
            }

            Access::Pending(count) => {
                let new_count = count + 1;
                println!("[{proto}][pending {new_count}/{SPAM_THRESHOLD}] {from}: {content}");
                if new_count >= SPAM_THRESHOLD {
                    let mut p = load_pending();
                    p.remove(&sender_hex);
                    save_pending(&p);
                    append_pubkey(&blocked_path(), &sender_hex);
                    println!("  → blocked (spam threshold reached)");
                    send_reply(&client, sender_pubkey,
                        "You have been blocked due to too many unauthorized attempts.").await;
                } else {
                    let mut p = load_pending();
                    p.insert(sender_hex.clone(), new_count);
                    save_pending(&p);
                    send_reply(&client, sender_pubkey,
                        "Your access request is still pending authorization.").await;
                }
            }

            Access::New => {
                let mut p = load_pending();
                p.insert(sender_hex.clone(), 1);
                save_pending(&p);
                println!("[{proto}][new] {from}: added to pending list");
                let welcome = format!(
                    "Hello! This is {VERSION}.\n\
                     Your contact request has been received and is pending admin authorization.\n\
                     \n\
                     https://github.com/zehrer/mChat"
                );
                send_reply(&client, sender_pubkey, &welcome).await;
            }
        }
    }

    Ok(())
}

// MARK: - Helpers

async fn send_reply(client: &Client, pubkey: PublicKey, text: &str) {
    match client.send_private_msg(pubkey, text, None).await {
        Ok(_) => println!("  → replied (NIP-17)"),
        Err(e) => println!("  → send failed: {e}"),
    }
}

async fn publish_profile(client: &Client, name: &str, about: &str) {
    let content = serde_json::json!({ "name": name, "about": about }).to_string();
    let builder = EventBuilder::new(Kind::Metadata, content, []);
    match client.send_event_builder(builder).await {
        Ok(_) => println!("Profile published: {name}"),
        Err(e) => eprintln!("[warn] Profile publish failed: {e}"),
    }
}

async fn publish_relay_list(client: &Client, relays: &[&str]) {
    let tags: Vec<Tag> = relays.iter().map(|r| Tag::parse(&["r", r]).unwrap()).collect();
    match client.send_event_builder(EventBuilder::new(Kind::RelayList, "", tags)).await {
        Ok(_) => println!("Relay list published (NIP-65)"),
        Err(e) => eprintln!("[warn] Relay list publish failed: {e}"),
    }
}

async fn publish_dm_relay_list(client: &Client, relays: &[&str]) {
    let tags: Vec<Tag> = relays.iter().map(|r| Tag::parse(&["relay", r]).unwrap()).collect();
    match client.send_event_builder(EventBuilder::new(Kind::Custom(10050), "", tags)).await {
        Ok(_) => println!("Relay list published (NIP-17)"),
        Err(e) => eprintln!("[warn] DM relay list publish failed: {e}"),
    }
}

fn shorten(hex: &str) -> String { format!("{}…", &hex[..12.min(hex.len())]) }
