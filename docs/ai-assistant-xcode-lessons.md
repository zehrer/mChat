# Lessons Learned: AI Coding Assistants Inside Xcode

*A practical field guide written from a real session in this repository where Claude (Claude Code, Opus 4.7) helped migrate the project from a Swift Package Manager layout to a real Xcode project, renamed the user-facing app, and tried to refactor folder structure. The mistakes and workarounds below are intended as feedback to the model developer.*

---

## 1. The Single Most Important Rule

**Never edit `*.xcodeproj/project.pbxproj` directly via any tool.** Not with `Write`, not with `Edit`, not with `sed`/`awk` in a shell.

### Why this matters

- Xcode keeps an in-memory representation of the project while it is open. An external edit can be silently overwritten when Xcode next saves, or — worse — leave Xcode and the file in disagreement, with corruption visible only after a restart.
- `project.pbxproj` is a plist-ish format with opaque object UUIDs that cross-reference each other across multiple sections (`PBXBuildFile`, `PBXFileReference`, `PBXGroup`, `PBXSourcesBuildPhase`, …). A single mis-edit in any section produces an unparseable project.
- Xcode auto-rewrites comment annotations (the `/* path/to/file.swift */` strings) every time the project is touched, so even "harmless" edits create noisy diffs.

### What to do instead

When project structure must change (add file to target, move file between groups, rename a group, change a build setting), **hand the work to the user with a precise plan**. The user performs the action in Xcode's Project Navigator, which writes `project.pbxproj` atomically. The assistant's job is to:

1. State the goal and the target structure.
2. Enumerate the exact files to move/rename and where they should land.
3. Wait for the user to confirm completion.
4. Verify via `git status` that the expected on-disk and project file changes appeared.
5. Continue with downstream work (commits, doc updates).

This rule is non-negotiable in this environment — a steering extension actively blocks attempts.

---

## 2. Xcode's Logical Structure vs. The Filesystem

The "project structure" shown in IDE context messages reflects Xcode's **logical group hierarchy**, not the on-disk layout. They are related but not equal.

### How `PBXGroup` works

```text
PBXGroup "Core"
  name  = Core              ← display name in Project Navigator
  path  = Sources/mChatCore ← on-disk folder this group represents
  children:
    - PBXFileReference "Backend/NostrBackend.swift"
    - PBXFileReference "Crypto/NIP04.swift"
    - …
```

Each child's `path` is **relative to its parent group's `path`**. So `Backend/NostrBackend.swift` inside the `Core` group resolves on disk to `Sources/mChatCore/Backend/NostrBackend.swift`.

### Consequences for an AI assistant

- **Project-structure context messages can be misleading.** A path like `mChat/Core/Backend/NostrBackend.swift` shown by Xcode may correspond to `Sources/mChatCore/Backend/NostrBackend.swift` on disk. Always verify with `Glob`, `git ls-files`, or `find` before any file operation.
- **Moving a file in Xcode** can either change the group it belongs to (logical move) or actually rewrite its on-disk path (physical move) — there's a "move files" checkbox in the Xcode dialog. When asking the user to perform moves, specify which you mean.
- **A group rename in Xcode** changes the `name` attribute but not the `path` — the on-disk folder is untouched. To actually rename the on-disk folder, the user must either change the group's `path` or move children individually.

---

## 3. Display Name vs. Code Identifiers

In this project, the app was renamed from "mChat" (which collides with an existing App Store app) to "mOpenChat" — but only the **user-visible display name** changed. Everything else stayed `mChat`:

| Surface | Name |
|---|---|
| App Store / SpringBoard display name | mOpenChat |
| GitHub repo | `mChat` |
| Xcode project file | `mChat.xcodeproj` |
| Xcode target & scheme | `mChat` |
| Swift module / folder names | `mChat`, `mChatCore` |
| Bundle identifier | `net.zehrer.mChat` |

The control point is `INFOPLIST_KEY_CFBundleDisplayName = mOpenChat` in the Xcode target's build settings.

### Lesson for the assistant

When a user says "rename the app", **always ask whether the rename is display-only or includes code identifiers.** A display-only rename is cheap (a build setting + doc updates); a full code rename involves the Xcode project, Swift modules, bundle ID, code-signing identifiers, App Store Connect record, and possibly the GitHub repo. Most of the time the user wants the former and assumes the assistant knows the difference.

When updating docs after a display-only rename, treat occurrences of the old name in **two distinct categories**:

- **Display references** (narrative copy, table headers, titles, README tagline) → rename
- **Code references** (paths like `Sources/mChat/`, module names like `mChatCore`, file names like `mChatApp.swift`, scheme names, bundle IDs) → keep verbatim

A blind `replace_all` will silently break code references that happen to share the old name.

---

## 4. The SPM → Xcode Migration Pattern

This project was originally an SPM package (`Package.swift` + `Sources/mChat/`, `Sources/mChatCore/`, `Tests/mChatCoreTests/`). The migration:

1. Created `mChat.xcodeproj` with a single iOS app target.
2. Compiled both `Sources/mChat/` and `Sources/mChatCore/` directly into that app target — no separate framework.
3. Wired the external `secp256k1.swift` dependency via Xcode's SwiftPM integration (an `XCRemoteSwiftPackageReference` in the project file).
4. Deleted `Package.swift` and `Tests/mChatCoreTests/` (the XCTest tests no longer build against the package; iOS tests using the Testing framework will be re-added inside the Xcode project).

### Important subtleties

- The on-disk folders **kept their original names** (`Sources/mChat/`, `Sources/mChatCore/`). Only the build system changed. This is a perfectly valid and common pattern — Xcode groups can have arbitrary `path` mappings.
- The folders are no longer "Swift modules" in the SPM sense — they're just folders that contribute source files to the single app target. Cross-folder code can `import` only the app's own module and external packages.
- Tests written with `XCTest` and discovered via `swift test` no longer run. The Xcode project's test target needs to be added separately.

### Lesson for the assistant

Don't assume the on-disk folder structure follows a particular convention just because Xcode displays it a certain way. Read `Package.swift` (if present) and `project.pbxproj` (read-only!) to understand the real layout. Don't trust path inference.

---

## 5. Folder Reorganization: A Workflow That Works

The user asked for the `Core` folder to be split into protocol-agnostic code (stays as `Sources/mChatCore/`) and Nostr-specific code (new `Sources/mChatNostr/`). The naive approach fails:

### ❌ What the assistant tried first

1. `git mv` the eight Nostr files from `Sources/mChatCore/` to a new `Sources/mChatNostr/`.
2. Try to rewrite `project.pbxproj` to update group children, file references, and source build phase entries.

The first step succeeded on disk; the second was blocked by the steering extension. Result: the working tree was momentarily broken (files moved but project still pointing at the old paths).

### ✅ Workflow that works

1. **Plan first.** Tell the user the exact target structure: which files move, where they land, what subfolders become empty.
2. **Hand off to the user.** Ask them to perform the moves in Xcode's Project Navigator. Xcode handles both the on-disk moves and the `project.pbxproj` updates atomically.
3. **Confirm via `git status`** that the expected file paths appeared.
4. **Run the build** (via `BuildProject` or `xcodebuild`) to confirm nothing broke.
5. **Commit and push** the result — that work belongs to the assistant.

If the on-disk file moves were already done before the rule was discovered, revert with `git mv` to a known-good state and start over with the correct workflow.

---

## 6. Things The Model Got Right (Worth Preserving)

- **Pre-pull stash + ff-only pull + pop:** When the local working tree was dirty and `origin/main` was ahead with non-conflicting commits, the assistant correctly stashed (with `-u` for untracked files), pulled fast-forward, and popped — avoiding any merge or rebase. This is the right reflex when remote changes are doc-only or otherwise non-overlapping.
- **Confirming intent before destructive git ops:** The assistant warned about uncommitted changes before pulling, listed incoming vs. local changes, and asked for permission. Good.
- **Splitting one PR into logical commits:** Migration and doc-rename were committed separately on the same branch even though they shipped in one PR. This makes review trivially easier.
- **Pushing back on a user's suggestion:** The user proposed renaming `mChatCore` → `mChatNostr` for "future-proofness." That reasoning actually argued for a *split* into `mChatCore` (generic) + `mChatNostr` (Nostr), not a full rename. The assistant explained the difference and asked the user to choose. The user picked the better option as a result.
- **Adding `.DS_Store` to `.gitignore` without being asked.** Small but matters.

---

## 7. Things The Model Should Be Trained To Do Differently

1. **Always check the on-disk layout before reasoning about Xcode "structure".** The Xcode context view can mislead.
2. **Recognize `*.xcodeproj/project.pbxproj` as a special, read-only-for-assistants file.** Same for `*.xcworkspace` and `xcuserdata/`. Treat them like lockfiles — read to understand, never write.
3. **When asked to "rename the app", ask whether it's display-only or code-deep.** Show the user the two-column table of "what to rename" vs "what to leave" before doing the work.
4. **When a rename appears in both display and code contexts inside the same file, do not use `replace_all`.** Plan the swap manually.
5. **Distinguish "folder rename / file move on disk" from "Xcode project structure change".** They are different operations with different blast radii.
6. **In any session running inside Xcode, assume Xcode itself is open.** This raises the cost of any project-file edit to near-infinite. Default to handing structural changes to the user.
7. **Be skeptical of project-structure context** that lists paths under `mChat/...` when the on-disk reality is `Sources/mChat/...`. Reconcile before acting.

---

## 8. Useful Commands & Tools Inventory

For an AI assistant working in this environment, here are the tools that actually work well:

| Task | Tool that works |
|---|---|
| Read Swift source | `Read` |
| Edit Swift source | `Edit` / `Write` |
| Find files by name pattern | `Glob` |
| Search code for keywords | `Grep` (ripgrep-backed) |
| Run a build | `BuildProject` (xcode-tools MCP) |
| Get inline diagnostics quickly | `XcodeRefreshCodeIssuesInFile` |
| Try out a code snippet | `ExecuteSnippet` |
| Search Apple docs (incl. post-cutoff APIs) | `DocumentationSearch` |
| Git operations | `Bash` with `git` (avoid `--no-verify`, never force-push to main) |
| Stage GitHub PRs | `gh` if installed, otherwise the URL from `git push` output |

And the tools that **don't** work / **shouldn't be used**:

| Anti-pattern | Why |
|---|---|
| `Write` on `project.pbxproj` | Blocked + dangerous (this whole doc is about that) |
| `find` / `ls` in `Bash` | Slow, generates permission prompts, prefer `Glob` / `XcodeLS` |
| `cat` / `head` / `tail` in `Bash` | Use `Read` instead |
| `sed` / `awk` in `Bash` | Use `Edit` instead |
| Blanket `replace_all` for renames spanning display + code | Will silently break code references |

---

## 9. One-Line Summary

> Inside Xcode, the assistant edits Swift; the user edits the project file. Cross that line and Xcode breaks.

---

*Document created 2026-05-24 as a session artifact. Intended for review by the assistant's developer team.*
