use nostr_sdk::prelude::*;
use std::{collections::HashSet, fs, path::PathBuf, time::Instant};

const VERSION: &str = "mRustChatd v0.0.2";

// MARK: - Config

#[derive(serde::Deserialize, Default)]
struct Config {
    rust: Option<ProfileConfig>,
}

#[derive(serde::Deserialize)]
struct ProfileConfig {
    name: Option<String>,
    about: Option<String>,
}

fn config_path() -> PathBuf {
    let home = std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    home.join(".mCLIChat").join("config.toml")
}

fn load_profile() -> (String, String) {
    let defaults = (
        VERSION.to_string(),
        "Rust Agent Daemon https://github.com/zehrer/mChat".to_string(),
    );
    let path = config_path();
    let content = match fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return defaults,
    };
    let config: Config = match toml::from_str(&content) {
        Ok(c) => c,
        Err(_) => return defaults,
    };
    match config.rust {
        Some(p) => (
            p.name.unwrap_or(defaults.0),
            p.about.unwrap_or(defaults.1),
        ),
        None => defaults,
    }
}

const DEFAULT_RELAYS: &[&str] = &[
    "wss://purplepag.es",
    "wss://nostr.wine",
    "wss://nos.lol",
];

fn key_path() -> PathBuf {
    let home = std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    home.join(".mCLIChat").join("mchatd.key")
}

fn load_or_create_keys() -> anyhow::Result<Keys> {
    let path = key_path();
    if path.exists() {
        if let Ok(hex) = fs::read_to_string(&path) {
            if let Ok(keys) = Keys::parse(hex.trim()) {
                return Ok(keys);
            }
        }
    }
    let keys = Keys::generate();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&path, keys.secret_key().to_secret_hex())?;
    println!("Generated new identity → {}", path.display());
    Ok(keys)
}

// MARK: - Commands

fn handle_command(
    text: &str,
    start_time: &Instant,
    msg_count: u64,
    known_senders: &HashSet<String>,
) -> String {
    let (cmd, args) = text
        .split_once(' ')
        .map(|(c, a)| (c, a.trim()))
        .unwrap_or((text, ""));

    match cmd {
        "/ping" => "pong".to_string(),

        "/echo" => {
            if args.is_empty() {
                "(empty)".to_string()
            } else {
                args.to_string()
            }
        }

        "/status" => {
            let uptime = format_uptime(start_time.elapsed());
            let relays = DEFAULT_RELAYS.join(", ");
            format!(
                "{VERSION}\nUptime: {uptime}\nRelays ({n}): {relays}\nMessages: {msg_count}\nKnown senders: {senders}",
                n = DEFAULT_RELAYS.len(),
                senders = known_senders.len(),
            )
        }

        "/user" => {
            if known_senders.is_empty() {
                "No known senders yet.".to_string()
            } else {
                let list = known_senders
                    .iter()
                    .map(|pk| format!("• {}", shorten(pk)))
                    .collect::<Vec<_>>()
                    .join("\n");
                format!("Known senders ({}):\n{}", known_senders.len(), list)
            }
        }

        "/help" => {
            "/ping — alive check\n\
             /echo <text> — send text back\n\
             /status — daemon info\n\
             /user — known senders\n\
             /help — this message"
                .to_string()
        }

        _ => format!("Unknown command: {cmd}\nTry /help"),
    }
}

fn format_uptime(d: std::time::Duration) -> String {
    let s = d.as_secs();
    let (h, m, s) = (s / 3600, (s % 3600) / 60, s % 60);
    if h > 0 {
        format!("{h}h {m}m {s}s")
    } else if m > 0 {
        format!("{m}m {s}s")
    } else {
        format!("{s}s")
    }
}

// MARK: - Main

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let keys = load_or_create_keys()?;
    println!("mRustChatd pubkey : {}", keys.public_key().to_hex());
    println!("mRustChatd npub   : {}", keys.public_key().to_bech32()?);

    let client = Client::new(keys.clone());
    for url in DEFAULT_RELAYS {
        client.add_relay(*url).await?;
    }
    client.connect().await;
    println!("Connected to {} relays.", DEFAULT_RELAYS.len());

    let mut notifications = client.notifications();

    client
        .subscribe(
            vec![
                Filter::new()
                    .pubkey(keys.public_key())
                    .kind(Kind::EncryptedDirectMessage),
                Filter::new()
                    .pubkey(keys.public_key())
                    .kind(Kind::GiftWrap),
            ],
            None,
        )
        .await?;

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
        let RelayPoolNotification::Event { event, .. } = notification else {
            continue;
        };
        if !seen.insert(event.id) {
            continue;
        }

        match event.kind {
            Kind::EncryptedDirectMessage => {
                let Ok(plain) =
                    nip04::decrypt(keys.secret_key(), &event.pubkey, &event.content)
                else {
                    continue;
                };
                let sender_hex = event.pubkey.to_hex();
                known_senders.insert(sender_hex.clone());
                msg_count += 1;
                let from = shorten(&sender_hex);
                println!("[NIP-04] {from}: {plain}");

                let reply = dispatch(&plain, &start_time, msg_count, &known_senders);
                match client.send_private_msg(event.pubkey, &reply, None).await {
                    Ok(_) => println!("  → replied (NIP-17)"),
                    Err(e) => println!("  → send failed: {e}"),
                }
            }

            Kind::GiftWrap => {
                let Ok(unwrapped) = client.unwrap_gift_wrap(&event).await else {
                    continue;
                };
                let inner = &unwrapped.rumor;
                let sender_hex = inner.pubkey.to_hex();
                known_senders.insert(sender_hex.clone());
                msg_count += 1;
                let from = shorten(&sender_hex);
                println!("[NIP-17] {from}: {}", inner.content);

                let reply = dispatch(&inner.content, &start_time, msg_count, &known_senders);
                match client.send_private_msg(inner.pubkey, &reply, None).await {
                    Ok(_) => println!("  → replied (NIP-17)"),
                    Err(e) => println!("  → send failed: {e}"),
                }
            }

            _ => {}
        }
    }

    Ok(())
}

fn dispatch(text: &str, start_time: &Instant, msg_count: u64, known_senders: &HashSet<String>) -> String {
    if text.starts_with('/') {
        handle_command(text, start_time, msg_count, known_senders)
    } else {
        format!("echo: {text}")
    }
}

// MARK: - Publish helpers

async fn publish_profile(client: &Client, name: &str, about: &str) {
    let content = serde_json::json!({ "name": name, "about": about }).to_string();
    let builder = EventBuilder::new(Kind::Metadata, content, []);
    match client.send_event_builder(builder).await {
        Ok(_) => println!("Profile published: {name}"),
        Err(e) => eprintln!("[warn] Profile publish failed: {e}"),
    }
}

async fn publish_relay_list(client: &Client, relays: &[&str]) {
    let tags: Vec<Tag> = relays
        .iter()
        .map(|r| Tag::parse(&["r", r]).unwrap())
        .collect();
    let builder = EventBuilder::new(Kind::RelayList, "", tags);
    match client.send_event_builder(builder).await {
        Ok(_) => println!("Relay list published (NIP-65)"),
        Err(e) => eprintln!("[warn] Relay list publish failed: {e}"),
    }
}

async fn publish_dm_relay_list(client: &Client, relays: &[&str]) {
    let tags: Vec<Tag> = relays
        .iter()
        .map(|r| Tag::parse(&["relay", r]).unwrap())
        .collect();
    let builder = EventBuilder::new(Kind::Custom(10050), "", tags);
    match client.send_event_builder(builder).await {
        Ok(_) => println!("Relay list published (NIP-17)"),
        Err(e) => eprintln!("[warn] DM relay list publish failed: {e}"),
    }
}

fn shorten(hex: &str) -> String {
    format!("{}…", &hex[..12.min(hex.len())])
}
