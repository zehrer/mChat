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
         whoami               Show your public / private key\n  \
         chat <pubkey>        Set active chat partner (then just type to send)\n  \
         send <pubkey> <msg>  Send a one-off DM\n  \
         help                 Show this help\n  \
         quit                 Disconnect and exit\n"
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

    let client = Client::new(keys.clone());

    for relay in DEFAULT_RELAYS {
        client.add_relay(*relay).await?;
    }

    println!("Connecting to Nostr relays…");
    client.connect().await;
    println!("Connected.\n");

    // Subscribe to incoming DMs addressed to us
    let filter = Filter::new()
        .pubkey(keys.public_key())
        .kind(Kind::EncryptedDirectMessage);
    client.subscribe(vec![filter], None).await?;

    // Background task: print incoming messages as they arrive
    let mut notifications = client.notifications();
    let sk = keys.secret_key().to_owned();
    tokio::spawn(async move {
        while let Ok(notification) = notifications.recv().await {
            if let RelayPoolNotification::Event { event, .. } = notification {
                if event.kind == Kind::EncryptedDirectMessage {
                    if let Ok(content) = nip04::decrypt(&sk, &event.pubkey, &event.content) {
                        let from = &event.pubkey.to_hex()[..12];
                        let time = format_time(event.created_at);
                        print!("\r[{time}] {from}…: {content}\n> ");
                        stdio::stdout().flush().ok();
                    }
                }
            }
        }
    });

    print_help();

    let stdin = BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();
    let mut active_peer: Option<PublicKey> = None;

    prompt();

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
                println!(
                    "Private key: {}  ← keep secret",
                    keys.secret_key().to_secret_hex()
                );
            }

            "chat" => {
                if arg1.is_empty() {
                    println!("Usage: chat <pubkey>");
                } else {
                    match PublicKey::from_hex(&arg1) {
                        Ok(pk) => {
                            println!("Chatting with {arg1}");
                            println!("Just type a message and press Enter to send.");
                            active_peer = Some(pk);
                        }
                        Err(_) => println!("Invalid pubkey"),
                    }
                }
            }

            "send" => {
                if arg1.is_empty() || rest.is_empty() {
                    println!("Usage: send <pubkey> <message>");
                } else {
                    match PublicKey::from_hex(&arg1) {
                        Ok(pk) => send_dm(&client, &pk, &rest).await,
                        Err(_) => println!("Invalid pubkey"),
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
