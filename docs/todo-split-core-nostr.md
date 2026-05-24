# TODO: Split `Core` into Generic Core + Nostr-Specific Folder

**Status:** Pending. The on-disk file moves and `project.pbxproj` updates must be done from inside Xcode (an AI assistant cannot safely edit `project.pbxproj` while Xcode is open). Until this is done, all Nostr-specific code still lives under `Sources/mChatCore/`.

**Why we're doing this:** The `MessagingBackend` abstraction in `Sources/mChatCore/Backend/MessagingBackend.swift` is protocol-agnostic — it is meant to be implemented by Nostr today and by Matrix, XMPP, SimpleX, etc. in the future. Keeping all of these inside a folder called `mChatCore` would muddle "generic core" with "one specific backend." Splitting now (before a second backend lands) gives every protocol its own folder.

**Resulting layout:**

```
Sources/
├── mChat/           # iOS app (unchanged)
├── mChatCore/       # protocol-agnostic
│   ├── Backend/MessagingBackend.swift
│   ├── Extensions.swift
│   └── Models/{ChatMessage,Contact,Conversation}.swift
└── mChatNostr/      # Nostr-specific (new)
    ├── NIP04.swift
    ├── NostrBackend.swift
    ├── NostrClient.swift
    ├── NostrError.swift
    ├── NostrEvent.swift
    ├── NostrFilter.swift
    ├── NostrKeyPair.swift
    └── NostrRelay.swift
```

Future backends each get their own sibling: `Sources/mChatMatrix/`, `Sources/mChatXMPP/`, …

---

## Step 1 — Create the new on-disk folder

In Finder (or via Xcode later), create an empty folder at:

```
/Users/stephan/Developement/Codex/mChat/Sources/mChatNostr
```

Right next to the existing `Sources/mChat/` and `Sources/mChatCore/`.

---

## Step 2 — Add the new folder to the Xcode project as a group

1. In Xcode's **Project Navigator** (left sidebar), select the project root `mChat` (the blue icon at the top).
2. **File → Add Files to "mChat"…**
3. In the file picker, select the `Sources/mChatNostr` folder you just created.
4. **Important options at the bottom of the dialog:**
   - **Added folders:** choose **"Create groups"** (NOT "Create folder references")
   - **Add to targets:** tick **mChat**
5. Click **Add.** A new empty group called `mChatNostr` appears.
6. (Optional cosmetic) Rename the group's display name from `mChatNostr` to `Nostr`: single-click the name, retype `Nostr`, hit Enter. This only changes the navigator label, not the folder path.

---

## Step 3 — Move the 8 Nostr files

In the Project Navigator, the following 8 files currently live inside the `Core` group. Move each one into the new `Nostr` group, and onto disk into `Sources/mChatNostr/`.

| From (inside `Core` group) | To (inside `Nostr` group) |
|---|---|
| `Backend/NostrBackend.swift` | `NostrBackend.swift` |
| `Crypto/NIP04.swift` | `NIP04.swift` |
| `Nostr/NostrClient.swift` | `NostrClient.swift` |
| `Nostr/NostrError.swift` | `NostrError.swift` |
| `Nostr/NostrEvent.swift` | `NostrEvent.swift` |
| `Nostr/NostrFilter.swift` | `NostrFilter.swift` |
| `Nostr/NostrKeyPair.swift` | `NostrKeyPair.swift` |
| `Nostr/NostrRelay.swift` | `NostrRelay.swift` |

**Critical:** the simple drag-drop in Xcode only changes the group, **not** the on-disk location. You need to also move the files on disk. Two reliable methods:

### Method A — File Inspector path repointing (per file)

1. Select a file in the navigator.
2. Open the **File Inspector** (right sidebar, top icon).
3. Under **Location**, click the small folder icon next to the path and re-point it to `Sources/mChatNostr/<filename>.swift`. This both moves the file on disk and updates the project reference.
4. Repeat for the other 7 files.

### Method B — Remove + Re-add (faster)

1. Select all 8 files in the navigator → right-click → **Delete** → choose **"Remove References Only"** (NOT "Move to Trash").
2. In Finder, physically move the 8 files from `Sources/mChatCore/Backend/`, `Sources/mChatCore/Crypto/`, and `Sources/mChatCore/Nostr/` into `Sources/mChatNostr/` (flat — no subfolders).
3. Back in Xcode, select the `Nostr` group → **File → Add Files to "mChat"…**, select the 8 files, ensure **"Create groups"** and **Add to target: mChat** are checked.

---

## Step 4 — Clean up empty folders

The `Sources/mChatCore/Crypto/` and `Sources/mChatCore/Nostr/` folders are now empty. Delete them in Finder (or leave them; git won't track empty folders). The `Sources/mChatCore/Backend/` folder stays — it still contains `MessagingBackend.swift`.

---

## Step 5 — Build to verify

**Product → Build** (`⌘B`). Should succeed without changes to any `.swift` file. If anything turns red in the navigator, the file reference is broken — fix it by re-pointing via the File Inspector.

---

## Step 6 — Verify with git

Open a terminal:

```sh
cd /Users/stephan/Developement/Codex/mChat
git status
```

You should see:

- New files under `Sources/mChatNostr/` (or renames if git detects them — `git status -M` will hint)
- 8 files deleted from `Sources/mChatCore/Crypto/` and `Sources/mChatCore/Nostr/`
- Modified `mChat.xcodeproj/project.pbxproj`

---

## Step 7 — Commit and push

If you've already opened a fresh Claude Code session, hand the cleanup to it. Otherwise, do it manually:

```sh
git add Sources/mChatNostr Sources/mChatCore mChat.xcodeproj
git commit -m "refactor: split Core into generic + Nostr-specific folders"
git push
```

If the PR `chore/xcode-migration-and-mopenchat-rename` is still open, push to that branch. If it's already merged, branch off `main` first.

---

## Step 8 — Update docs

After the split lands, update `SETUP.md` and `README.md` "Project Layout" sections to reflect the new `Sources/mChatNostr/` folder and the protocol-neutral framing of `Sources/mChatCore/`.

---

## Why an AI assistant can't do this directly

Editing `mChat.xcodeproj/project.pbxproj` while Xcode is open will almost always corrupt the project or crash Xcode. The harness blocks direct edits. See `docs/ai-assistant-xcode-lessons.md` for the longer rationale and the workflow that does work.
