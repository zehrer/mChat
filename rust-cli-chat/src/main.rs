use nostr_sdk::prelude::*;
use std::{
    fs,
    io::{self as stdio, Write},
    path::PathBuf,
};
use tokio::io::{AsyncBufReadExt, BufReader};

const DEFAULT_RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://relay.nostr.band",
    "wss://nos.lol",
    "wss://relay.snort.social",
];

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

// Accepts both hex (64-char) and bech32 npub1... format.
fn parse_pubkey(s: &str) -> anyhow::Result<PublicKey> {
    PublicKey::parse(s).map_err(|e| anyhow::anyhow!("Invalid pubkey '{}': {}", s, e))
}

// MARK: - Sending

async fn send_dm(client: &Client, recipient: &PublicKey, text: &str) {
    match client.send_private_msg(*recipient, text, None).await {
        Ok(_) => println!("[sent]"),
        Err(e) => println!("Send failed: {e}"),
    }
}

// MARK: - UI helpers

fn print_help() {
    println!(
        "\nCommands:\n  \
         whoami                Show your public key / npub / private key\n  \
         chat <npub|pubkey>    Set active chat partner (then just type to send)\n  \
         send <npub|pubkey> <msg>  Send a one-off DM\n  \
         relays                List connected relays\n  \
         help                  Show this help\n  \
         quit                  Disconnect and exit\n"
    );
}

fn format_time(ts: Timestamp) -> String {
    let secs = ts.as_u64();
    let hours = (secs % 86400) / 3600;
    let mins = (secs % 3600) / 60;
    format!("{:02}:{:02}", hours, mins)
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
    println!("Connected to {} relays.\n", DEFAULT_RELAYS.len());

    // Subscribe: recent history (last 50 DMs) + live feed
    let filter = Filter::new()
        .pubkey(keys.public_key())
        .kind(Kind::EncryptedDirectMessage)
        .limit(50);
    client.subscribe(vec![filter], None).await?;

    // Background task: print incoming messages and mark end-of-history
    let mut notifications = client.notifications();
    let sk = keys.secret_key().to_owned();
    tokio::spawn(async move {
        let mut history_done = false;
        while let Ok(notification) = notifications.recv().await {
            match notification {
                RelayPoolNotification::Event { event, .. } => {
                    if event.kind == Kind::EncryptedDirectMessage {
                        if let Ok(content) = nip04::decrypt(&sk, &event.pubkey, &event.content) {
                            let from = &event.pubkey.to_hex()[..12];
                            let time = format_time(event.created_at);
                            if history_done {
                                // Overwrite the "> " prompt line, then reprint it
                                print!("\r[{time}] {from}…: {content}\n> ");
                            } else {
                                print!("[{time}] {from}…: {content}\n");
                            }
                            stdio::stdout().flush().ok();
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
                println!(
                    "Private key: {}  ← keep secret",
                    keys.secret_key().to_secret_hex()
                );
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
                    println!("Usage: chat <npub or pubkey hex>");
                } else {
                    match parse_pubkey(&arg1) {
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
                    println!("Usage: send <npub or pubkey hex> <message>");
                } else {
                    match parse_pubkey(&arg1) {
                        Ok(pk) => send_dm(&client, &pk, &rest).await,
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
                    send_dm(&client, peer, &line).await;
                } else {
                    println!("Unknown command. Type 'help' for commands.");
                }
            }
        }

        prompt();
    }

    Ok(())
}
