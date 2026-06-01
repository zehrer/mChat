use nostr_sdk::prelude::*;
use std::{collections::{HashMap, HashSet}, fs, path::PathBuf, time::{Duration, Instant}};

const VERSION: &str = "mRustChatd v0.0.2";
const SPAM_THRESHOLD: u32 = 5;
// Relay backlog on startup can replay many messages at once; ignore pending/new
// spam counting during this window to avoid false auto-blocks.
const STARTUP_GRACE_SECS: u64 = 15;

// MARK: - Paths

fn mclichat_dir() -> PathBuf {
    // MCLICHAT_DIR overrides the default; used in unit tests to avoid touching prod data.
    if let Ok(dir) = std::env::var("MCLICHAT_DIR") {
        return PathBuf::from(dir);
    }
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(".mCLIChat")
}

fn config_path()     -> PathBuf { mclichat_dir().join("config.toml") }
fn key_path()        -> PathBuf { mclichat_dir().join("mchatd.key") }
fn whitelist_path()  -> PathBuf { mclichat_dir().join("whitelist.txt") }
fn blocked_path()    -> PathBuf { mclichat_dir().join("blocked.txt") }
fn pending_path()    -> PathBuf { mclichat_dir().join("pending.json") }
fn users_path()      -> PathBuf { mclichat_dir().join("users.json") }
fn roles_path()      -> PathBuf { mclichat_dir().join("roles.json") }
fn last_seen_path()  -> PathBuf { mclichat_dir().join("last_seen.txt") }

// Persist the high-water mark across restarts so relay backlog isn't re-processed.
// Defaults to now on first run to avoid processing historical backlog.
fn load_last_seen() -> u64 {
    fs::read_to_string(last_seen_path())
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or_else(|| Timestamp::now().as_u64())
}

fn save_last_seen(ts: u64) {
    let _ = fs::write(last_seen_path(), ts.to_string());
}

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

// MARK: - User registry

#[derive(serde::Deserialize, serde::Serialize, Clone, Default)]
struct UserInfo {
    id: u32,
    #[serde(default)]
    nip05: String,  // preferred: NIP-05 identifier (e.g. user@domain.com)
    #[serde(default)]
    name: String,   // fallback: name field from kind:0
}

fn load_users() -> HashMap<String, UserInfo> {
    serde_json::from_str(&fs::read_to_string(users_path()).unwrap_or_default())
        .unwrap_or_default()
}

fn save_users(users: &HashMap<String, UserInfo>) {
    if let Ok(json) = serde_json::to_string_pretty(users) {
        let _ = fs::write(users_path(), json);
    }
}

async fn fetch_metadata(client: &Client, pubkey: PublicKey) -> (String, String) {
    let meta = fetch_profile(client, pubkey).await;
    let get = |k: &str| meta.as_ref().and_then(|m| m[k].as_str()).unwrap_or("").to_string();
    (get("nip05"), get("name"))
}

async fn fetch_profile(client: &Client, pubkey: PublicKey) -> Option<serde_json::Value> {
    let filter = Filter::new().author(pubkey).kind(Kind::Metadata).limit(1);
    client.fetch_events(vec![filter], Some(Duration::from_secs(5))).await.ok()?
        .into_iter().next()
        .and_then(|e| serde_json::from_str(&e.content).ok())
}

async fn get_or_register(client: &Client, pubkey_hex: &str, pubkey: PublicKey) -> UserInfo {
    let mut users = load_users();
    // Re-fetch if entry exists but both name fields are empty (e.g. after a cache clear)
    let needs_fetch = users.get(pubkey_hex)
        .map(|u| u.nip05.is_empty() && u.name.is_empty())
        .unwrap_or(true);

    if needs_fetch {
        let id = users.get(pubkey_hex).map(|u| u.id)
            .unwrap_or_else(|| users.values().map(|u| u.id).max().unwrap_or(0) + 1);
        let (nip05, name) = fetch_metadata(client, pubkey).await;
        let info = UserInfo { id, nip05, name };
        users.insert(pubkey_hex.to_string(), info.clone());
        save_users(&users);
        info
    } else {
        users[pubkey_hex].clone()
    }
}

fn display_name(info: &UserInfo, pubkey_hex: &str) -> String {
    let label = if !info.nip05.is_empty() { &info.nip05 }
                else if !info.name.is_empty() { &info.name }
                else { return format!("#{} ({})", info.id, shorten(pubkey_hex)); };
    format!("#{} {}", info.id, label)
}

// MARK: - Roles

#[derive(serde::Deserialize, serde::Serialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "lowercase")]
enum Role { Admin, User }

impl std::fmt::Display for Role {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self { Role::Admin => write!(f, "admin"), Role::User => write!(f, "user") }
    }
}

fn load_roles() -> HashMap<String, Role> {
    serde_json::from_str(&fs::read_to_string(roles_path()).unwrap_or_default())
        .unwrap_or_default()
}

fn save_roles(roles: &HashMap<String, Role>) {
    if let Ok(json) = serde_json::to_string_pretty(roles) {
        let _ = fs::write(roles_path(), json);
    }
}

// No explicit entry in roles.json → user (admin must be set locally in roles.json)
fn get_role(pubkey: &str) -> Role {
    load_roles().remove(pubkey).unwrap_or(Role::User)
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

fn remove_pubkey(path: &PathBuf, pubkey: &str) {
    let existing = fs::read_to_string(path).unwrap_or_default();
    let filtered: String = existing.lines()
        .filter(|l| l.trim() != pubkey)
        .map(|l| format!("{l}\n"))
        .collect();
    let _ = fs::write(path, filtered);
}

fn pubkey_for_id(id: u32) -> Option<(String, UserInfo)> {
    load_users().into_iter().find(|(_, u)| u.id == id)
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

fn handle_command(text: &str, caller_role: &Role, start_time: &Instant, msg_count: u64) -> String {
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
                 Messages: {msg_count}\nAuthorized: {authorized} | Pending: {pending} | Blocked: {blocked}",
                n = DEFAULT_RELAYS.len(),
            )
        }

        "/user" => {
            let mut users = load_users();
            let roles    = load_roles();
            let whitelist = load_pubkey_file(&whitelist_path());
            let pending  = load_pending();
            let blocked  = load_pubkey_file(&blocked_path());

            // Lazily assign IDs to any listed pubkey not yet in users.json so
            // every user shown here has an #ID that /authorize and /block can target.
            let mut dirty = false;
            for pk in whitelist.iter().chain(pending.keys()).chain(blocked.iter()) {
                if !users.contains_key(pk) {
                    let next_id = users.values().map(|u| u.id).max().unwrap_or(0) + 1;
                    users.insert(pk.clone(), UserInfo { id: next_id, nip05: String::new(), name: String::new() });
                    dirty = true;
                }
            }
            if dirty { save_users(&users); }

            let mut entries: Vec<(u32, String)> = vec![];

            for pk in &whitelist {
                let role = roles.get(pk).unwrap_or(&Role::Admin);
                let u = &users[pk];
                entries.push((u.id, format!("{}  [auth][{role}]", display_name(u, pk))));
            }
            for (pk, n) in &pending {
                let u = &users[pk];
                entries.push((u.id, format!("{}  [pending {n}/{SPAM_THRESHOLD}]", display_name(u, pk))));
            }
            for pk in &blocked {
                let u = &users[pk];
                entries.push((u.id, format!("{}  [blocked]", display_name(u, pk))));
            }

            if entries.is_empty() { return "No senders yet.".to_string(); }
            entries.sort_by_key(|(id, _)| *id);
            entries.into_iter().map(|(_, s)| s).collect::<Vec<_>>().join("\n")
        }

        "/authorize" => {
            let Ok(id) = args.parse::<u32>() else {
                return "Usage: /authorize <id>".to_string();
            };
            match pubkey_for_id(id) {
                None => format!("No user with id #{id}"),
                Some((pubkey, info)) => {
                    let mut p = load_pending(); p.remove(&pubkey); save_pending(&p);
                    remove_pubkey(&blocked_path(), &pubkey);
                    if !load_pubkey_file(&whitelist_path()).contains(&pubkey) {
                        append_pubkey(&whitelist_path(), &pubkey);
                    }
                    // Explicitly added via command → user role (unless already admin)
                    let mut roles = load_roles();
                    roles.entry(pubkey.clone()).or_insert(Role::User);
                    save_roles(&roles);
                    format!("{} authorized.", display_name(&info, &pubkey))
                }
            }
        }

        "/block" => {
            if caller_role != &Role::Admin {
                return "Permission denied: only admins can block users.".to_string();
            }
            let Ok(id) = args.parse::<u32>() else {
                return "Usage: /block <id>".to_string();
            };
            match pubkey_for_id(id) {
                None => format!("No user with id #{id}"),
                Some((pubkey, info)) => {
                    let mut p = load_pending(); p.remove(&pubkey); save_pending(&p);
                    remove_pubkey(&whitelist_path(), &pubkey);
                    if !load_pubkey_file(&blocked_path()).contains(&pubkey) {
                        append_pubkey(&blocked_path(), &pubkey);
                    }
                    format!("{} blocked.", display_name(&info, &pubkey))
                }
            }
        }

        "/help" => format!(
            "/ping — alive check\n\
             /echo <text> — send text back\n\
             /status — daemon info\n\
             /user — sender list with IDs, access state and role\n\
             /user details <id> — full profile (re-fetches from relays)\n\
             /authorize <id> — grant full access\n\
             /block <id> — block a user (admin only)\n\
             /help — this message\n\
             Your role: {caller_role}"
        ),

        _ => format!("Unknown command: {cmd}\nTry /help"),
    }
}

fn format_uptime(d: Duration) -> String {
    let s = d.as_secs();
    let (h, m, s) = (s / 3600, (s % 3600) / 60, s % 60);
    if h > 0 { format!("{h}h {m}m {s}s") }
    else if m > 0 { format!("{m}m {s}s") }
    else { format!("{s}s") }
}

fn dispatch(text: &str, role: &Role, start_time: &Instant, msg_count: u64) -> String {
    if text.starts_with('/') { handle_command(text, role, start_time, msg_count) }
    else { format!("echo: {text}") }
}

async fn dispatch_with_client(text: &str, role: &Role, start_time: &Instant, msg_count: u64, client: &Client) -> String {
    let trimmed = text.trim();
    if let Some(rest) = trimmed.strip_prefix("/user details") {
        return cmd_user_details(rest.trim(), client).await;
    }
    dispatch(text, role, start_time, msg_count)
}

async fn cmd_user_details(args: &str, client: &Client) -> String {
    let id_str = args.trim_start_matches('#');
    let Ok(id) = id_str.parse::<u32>() else {
        return "Usage: /user details <id>".to_string();
    };
    let Some((pubkey_hex, _)) = pubkey_for_id(id) else {
        return format!("No user with id #{id}");
    };
    let Ok(pubkey) = PublicKey::from_hex(&pubkey_hex) else {
        return "Invalid pubkey stored for that user.".to_string();
    };

    let meta = fetch_profile(client, pubkey).await;
    let get = |key: &str| -> String {
        meta.as_ref()
            .and_then(|m| m[key].as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("-")
            .to_string()
    };

    let nip05        = get("nip05");
    let name         = get("name");
    let display_name = get("display_name");
    let about        = get("about");
    let website      = get("website");
    let lud16        = get("lud16");
    let picture      = get("picture");

    // Persist fresh name data so /user benefits next time
    let mut users = load_users();
    if let Some(u) = users.get_mut(&pubkey_hex) {
        if nip05 != "-" { u.nip05 = nip05.clone(); }
        if name != "-"  { u.name  = name.clone(); }
        save_users(&users);
    }

    let whitelist = load_pubkey_file(&whitelist_path());
    let blocked   = load_pubkey_file(&blocked_path());
    let pending   = load_pending();
    let status = if whitelist.contains(&pubkey_hex)     { "authorized".to_string() }
                 else if blocked.contains(&pubkey_hex)  { "blocked".to_string() }
                 else if let Some(n) = pending.get(&pubkey_hex) {
                     format!("pending ({n}/{SPAM_THRESHOLD})")
                 } else { "unknown".to_string() };

    let role = load_roles().get(&pubkey_hex).cloned().unwrap_or(Role::User);
    let npub = pubkey.to_bech32().unwrap_or_else(|_| "-".to_string());

    let label = if nip05 != "-" { nip05.clone() }
                else if name != "-" { name.clone() }
                else { shorten(&pubkey_hex) };

    format!(
        "#{id} {label}\n\
         Status:   {status}\n\
         Role:     {role}\n\
         NIP-05:   {nip05}\n\
         Name:     {name}\n\
         Display:  {display_name}\n\
         About:    {about}\n\
         Website:  {website}\n\
         LN addr:  {lud16}\n\
         Picture:  {picture}\n\
         npub:     {npub}\n\
         pubkey:   {pubkey_hex}"
    )
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
    let mut last_seen_ts = load_last_seen();

    while let Ok(notification) = notifications.recv().await {
        let RelayPoolNotification::Event { event, .. } = notification else { continue };
        if !seen.insert(event.id) { continue; }

        let (sender_pubkey, sender_hex, content, msg_ts) = match event.kind {
            Kind::EncryptedDirectMessage => {
                let Ok(plain) = nip04::decrypt(keys.secret_key(), &event.pubkey, &event.content)
                else { continue };
                (event.pubkey, event.pubkey.to_hex(), plain, event.created_at.as_u64())
            }
            Kind::GiftWrap => {
                let Ok(unwrapped) = client.unwrap_gift_wrap(&event).await else { continue };
                let inner = unwrapped.rumor;
                // Use inner rumor timestamp — outer gift-wrap timestamp is randomized (NIP-59)
                let ts = inner.created_at.as_u64();
                (inner.pubkey, inner.pubkey.to_hex(), inner.content, ts)
            }
            _ => continue,
        };

        // Skip relay backlog from previous sessions; advance the high-water mark
        if msg_ts <= last_seen_ts {
            continue;
        }
        last_seen_ts = msg_ts;
        save_last_seen(last_seen_ts);

        let proto = if event.kind == Kind::GiftWrap { "NIP-17" } else { "NIP-04" };

        // Register user on first contact (fetches display name)
        let user = get_or_register(&client, &sender_hex, sender_pubkey).await;
        let label = display_name(&user, &sender_hex);

        match check_access(&sender_hex) {
            Access::Authorized => {
                msg_count += 1;
                let role = get_role(&sender_hex);
                println!("[{proto}][auth][{role}] {label}: {content}");
                let reply = dispatch_with_client(&content, &role, &start_time, msg_count, &client).await;
                send_reply(&client, sender_pubkey, &reply).await;
            }

            Access::Blocked => {
                println!("[{proto}][blocked] {label}: ignored");
            }

            Access::Pending(count) => {
                // Skip spam counting during startup grace period to avoid
                // false auto-blocks from relay backlog replays.
                if start_time.elapsed().as_secs() < STARTUP_GRACE_SECS {
                    println!("[{proto}][pending {count}/{SPAM_THRESHOLD}][grace] {label}: skipped");
                    continue;
                }
                let new_count = count + 1;
                println!("[{proto}][pending {new_count}/{SPAM_THRESHOLD}] {label}: {content}");
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
                // Skip welcome during startup grace period; those messages were
                // sent before the daemon started and likely already got a reply.
                if start_time.elapsed().as_secs() < STARTUP_GRACE_SECS {
                    println!("[{proto}][new][grace] {label}: skipped");
                    continue;
                }
                let mut p = load_pending();
                p.insert(sender_hex.clone(), 1);
                save_pending(&p);
                println!("[{proto}][new] {label}: added to pending list");
                let welcome = format!(
                    "Hello! This is {VERSION}.\n\
                     Your contact request has been received and is pending admin authorization.\n\
                     \nhttps://github.com/zehrer/mChat"
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
    match client.send_event_builder(EventBuilder::new(Kind::Metadata, content, [])).await {
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

fn shorten(hex: &str) -> String { format!("{}…", &hex[..16.min(hex.len())]) }

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    // ── Helpers ──────────────────────────────────────────────────────────────

    use std::sync::Mutex;

    // Serialize all tests that touch the file system via MCLICHAT_DIR so they
    // don't race on the process-wide environment variable.
    static DIR_LOCK: Mutex<()> = Mutex::new(());

    fn with_tmp_dir<F: FnOnce(&std::path::Path)>(f: F) {
        let _guard = DIR_LOCK.lock().unwrap();
        let dir = tempfile::tempdir().expect("tempdir");
        std::env::set_var("MCLICHAT_DIR", dir.path());
        f(dir.path());
        std::env::remove_var("MCLICHAT_DIR");
    }

    // ── format_uptime ────────────────────────────────────────────────────────

    #[test]
    fn uptime_seconds_only() {
        assert_eq!(format_uptime(Duration::from_secs(0)),  "0s");
        assert_eq!(format_uptime(Duration::from_secs(1)),  "1s");
        assert_eq!(format_uptime(Duration::from_secs(59)), "59s");
    }

    #[test]
    fn uptime_minutes() {
        assert_eq!(format_uptime(Duration::from_secs(60)),   "1m 0s");
        assert_eq!(format_uptime(Duration::from_secs(90)),   "1m 30s");
        assert_eq!(format_uptime(Duration::from_secs(3599)), "59m 59s");
    }

    #[test]
    fn uptime_hours() {
        assert_eq!(format_uptime(Duration::from_secs(3600)),  "1h 0m 0s");
        assert_eq!(format_uptime(Duration::from_secs(3661)),  "1h 1m 1s");
        assert_eq!(format_uptime(Duration::from_secs(7322)),  "2h 2m 2s");
    }

    // ── shorten ──────────────────────────────────────────────────────────────

    #[test]
    fn shorten_64char_hex() {
        let hex = "199a88c12350258a5ceeabb3c65b8e1576bab62f8ff05f9b1ba32c015d9fe15f";
        let s = shorten(hex);
        assert!(s.starts_with("199a88c12350258a"));
        assert!(s.ends_with('…'));
    }

    #[test]
    fn shorten_short_input_no_panic() {
        let s = shorten("abc");
        assert_eq!(s, "abc…");
    }

    // ── display_name ─────────────────────────────────────────────────────────

    #[test]
    fn display_name_prefers_nip05() {
        let info = UserInfo { id: 1, nip05: "user@example.com".into(), name: "User".into() };
        assert_eq!(display_name(&info, "aabbcc"), "#1 user@example.com");
    }

    #[test]
    fn display_name_falls_back_to_name() {
        let info = UserInfo { id: 2, nip05: "".into(), name: "Alice".into() };
        assert_eq!(display_name(&info, "aabbcc"), "#2 Alice");
    }

    #[test]
    fn display_name_truncates_pubkey() {
        let info = UserInfo { id: 3, nip05: "".into(), name: "".into() };
        let pk = "1234567890abcdef9999";
        let result = display_name(&info, pk);
        assert_eq!(result, "#3 (1234567890abcdef…)");
    }

    // ── dispatch ─────────────────────────────────────────────────────────────

    #[test]
    fn dispatch_plain_text_echoes() {
        let t = Instant::now();
        assert_eq!(dispatch("hello world", &Role::User, &t, 0), "echo: hello world");
    }

    #[test]
    fn dispatch_routes_commands() {
        let t = Instant::now();
        assert_eq!(dispatch("/ping", &Role::User, &t, 0), "pong");
    }

    // ── commands ─────────────────────────────────────────────────────────────

    #[test]
    fn cmd_ping() {
        let t = Instant::now();
        assert_eq!(handle_command("/ping", &Role::User, &t, 0), "pong");
    }

    #[test]
    fn cmd_echo_with_args() {
        let t = Instant::now();
        assert_eq!(handle_command("/echo hello world", &Role::User, &t, 0), "hello world");
    }

    #[test]
    fn cmd_echo_empty() {
        let t = Instant::now();
        assert_eq!(handle_command("/echo", &Role::User, &t, 0), "(empty)");
    }

    #[test]
    fn cmd_unknown() {
        let t = Instant::now();
        let r = handle_command("/xyz", &Role::User, &t, 0);
        assert!(r.contains("Unknown command: /xyz"));
        assert!(r.contains("Try /help"));
    }

    #[test]
    fn cmd_help_contains_all_commands() {
        let t = Instant::now();
        let r = handle_command("/help", &Role::Admin, &t, 0);
        for cmd in &["/ping", "/echo", "/status", "/user", "/authorize", "/block", "/help"] {
            assert!(r.contains(cmd), "help missing {cmd}");
        }
    }

    #[test]
    fn cmd_help_shows_role() {
        let t = Instant::now();
        assert!(handle_command("/help", &Role::Admin, &t, 0).contains("admin"));
        assert!(handle_command("/help", &Role::User,  &t, 0).contains("user"));
    }

    #[test]
    fn cmd_block_requires_admin() {
        let t = Instant::now();
        let r = handle_command("/block 1", &Role::User, &t, 0);
        assert!(r.contains("Permission denied"));
    }

    #[test]
    fn cmd_block_bad_arg() {
        let t = Instant::now();
        let r = handle_command("/block abc", &Role::Admin, &t, 0);
        assert!(r.contains("Usage: /block"));
    }

    #[test]
    fn cmd_authorize_bad_arg() {
        let t = Instant::now();
        let r = handle_command("/authorize abc", &Role::User, &t, 0);
        assert!(r.contains("Usage: /authorize"));
    }

    // ── file-based tests (use MCLICHAT_DIR) ──────────────────────────────────

    #[test]
    fn load_pubkey_file_skips_comments_and_blanks() {
        with_tmp_dir(|dir| {
            let path = dir.join("test.txt");
            fs::write(&path, "# comment\n\naabbccdd\n  # another\neeff1122\n").unwrap();
            let set = load_pubkey_file(&path);
            assert_eq!(set.len(), 2);
            assert!(set.contains("aabbccdd"));
            assert!(set.contains("eeff1122"));
        });
    }

    #[test]
    fn check_access_new_sender() {
        with_tmp_dir(|_dir| {
            let access = check_access("unknownpubkey");
            assert!(matches!(access, Access::New));
        });
    }

    #[test]
    fn check_access_whitelisted() {
        with_tmp_dir(|_dir| {
            fs::create_dir_all(mclichat_dir()).unwrap();
            append_pubkey(&whitelist_path(), "authorizedkey");
            assert!(matches!(check_access("authorizedkey"), Access::Authorized));
        });
    }

    #[test]
    fn check_access_blocked() {
        with_tmp_dir(|_dir| {
            fs::create_dir_all(mclichat_dir()).unwrap();
            append_pubkey(&blocked_path(), "blockedkey");
            assert!(matches!(check_access("blockedkey"), Access::Blocked));
        });
    }

    #[test]
    fn check_access_pending() {
        with_tmp_dir(|_dir| {
            fs::create_dir_all(mclichat_dir()).unwrap();
            let mut p = HashMap::new();
            p.insert("pendingkey".to_string(), 3u32);
            save_pending(&p);
            assert!(matches!(check_access("pendingkey"), Access::Pending(3)));
        });
    }

    #[test]
    fn check_access_whitelist_takes_priority_over_pending() {
        with_tmp_dir(|_dir| {
            fs::create_dir_all(mclichat_dir()).unwrap();
            append_pubkey(&whitelist_path(), "bothkey");
            let mut p = HashMap::new();
            p.insert("bothkey".to_string(), 2u32);
            save_pending(&p);
            assert!(matches!(check_access("bothkey"), Access::Authorized));
        });
    }

    #[test]
    fn get_role_defaults_to_user() {
        with_tmp_dir(|_dir| {
            fs::create_dir_all(mclichat_dir()).unwrap();
            assert_eq!(get_role("anypubkey"), Role::User);
        });
    }

    #[test]
    fn get_role_admin_from_file() {
        with_tmp_dir(|_dir| {
            fs::create_dir_all(mclichat_dir()).unwrap();
            let mut roles = HashMap::new();
            roles.insert("adminkey".to_string(), Role::Admin);
            save_roles(&roles);
            assert_eq!(get_role("adminkey"), Role::Admin);
        });
    }

    #[test]
    fn ensure_whitelist_creates_file_with_header() {
        with_tmp_dir(|_dir| {
            fs::create_dir_all(mclichat_dir()).unwrap();
            assert!(!whitelist_path().exists());
            ensure_whitelist();
            assert!(whitelist_path().exists());
            let content = fs::read_to_string(whitelist_path()).unwrap();
            assert!(content.contains('#'), "header comment should be present");
        });
    }

    #[test]
    fn ensure_whitelist_is_idempotent() {
        with_tmp_dir(|_dir| {
            fs::create_dir_all(mclichat_dir()).unwrap();
            fs::write(whitelist_path(), "existingkey\n").unwrap();
            ensure_whitelist();
            let content = fs::read_to_string(whitelist_path()).unwrap();
            assert_eq!(content, "existingkey\n");
        });
    }
}
