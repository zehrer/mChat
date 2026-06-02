use std::{collections::HashMap, fs, path::PathBuf};

/// alias → pubkey (hex or bech32 as stored by the user)
pub type Contacts = HashMap<String, String>;

pub fn contacts_path() -> PathBuf {
    let home = std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    home.join(".mCLIChat").join("contacts.json")
}

pub fn load() -> Contacts {
    let path = contacts_path();
    if path.exists() {
        if let Ok(data) = fs::read_to_string(&path) {
            if let Ok(c) = serde_json::from_str(&data) {
                return c;
            }
        }
    }
    Contacts::new()
}

pub fn save(contacts: &Contacts) -> anyhow::Result<()> {
    let data = serde_json::to_string_pretty(contacts)?;
    fs::write(contacts_path(), data)?;
    Ok(())
}
