use nostr_sdk::prelude::*;
use std::{collections::HashSet, fs, path::PathBuf};

const DEFAULT_RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://relay.nostr.band",
    "wss://nos.lol",
    "wss://relay.snort.social",
    "wss://nostr.wine",
    "wss://relay.current.fyi",
    "wss://purplepag.es",
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

    publish_profile(&client, "mRustChatd", "Rust echo daemon — replies with 'echo: <message>'").await;
    publish_relay_list(&client, DEFAULT_RELAYS).await;
    println!("Listening for DMs… Ctrl+C to stop.\n");

    let mut seen: HashSet<EventId> = HashSet::new();

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
                let from = shorten(&event.pubkey.to_hex());
                println!("[NIP-04] {from}: {plain}");

                let reply = format!("echo: {plain}");
                match nip04::encrypt(keys.secret_key(), &event.pubkey, &reply) {
                    Ok(encrypted) => {
                        let builder = EventBuilder::new(
                            Kind::EncryptedDirectMessage,
                            encrypted,
                            [Tag::public_key(event.pubkey)],
                        );
                        match client.send_event_builder(builder).await {
                            Ok(_) => println!("  → echoed (NIP-04)"),
                            Err(e) => println!("  → send failed: {e}"),
                        }
                    }
                    Err(e) => println!("  → encrypt failed: {e}"),
                }
            }

            Kind::GiftWrap => {
                let Ok(unwrapped) = client.unwrap_gift_wrap(&event).await else {
                    continue;
                };
                let inner = &unwrapped.rumor;
                let from = shorten(&inner.pubkey.to_hex());
                println!("[NIP-17] {from}: {}", inner.content);

                let reply = format!("echo: {}", inner.content);
                match client.send_private_msg(inner.pubkey, &reply, None).await {
                    Ok(_) => println!("  → echoed (NIP-17)"),
                    Err(e) => println!("  → send failed: {e}"),
                }
            }

            _ => {}
        }
    }

    Ok(())
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

fn shorten(hex: &str) -> String {
    format!("{}…", &hex[..12.min(hex.len())])
}
