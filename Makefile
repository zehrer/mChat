SWIFT        := $(HOME)/.local/share/swiftly/bin/swift
SWIFT_BIN    := .build/x86_64-unknown-linux-gnu
RUST_BIN     := rust-cli-chat/target
RUST_LOG     := /tmp/mchatd_out.log

# mSwiftChatd is suspended — development focus is on mRustChatd.
# Swift targets kept for reference but excluded from deploy/test/run.

# ---------------------------------------------------------------------------
# deploy: release build + restart (primary development loop)
# ---------------------------------------------------------------------------
.PHONY: deploy
deploy: build-rust-release stop
	nohup $(RUST_BIN)/release/mRustChatd >> $(RUST_LOG) 2>&1 &
	@echo "mRustChatd restarted. Log: $(RUST_LOG)"

# ---------------------------------------------------------------------------
# test: unit tests
# ---------------------------------------------------------------------------
.PHONY: test test-rust test-rust-verbose
test: test-rust

test-rust:
	cd rust-cli-chat && cargo test --bin mRustChatd

test-rust-verbose:
	cd rust-cli-chat && cargo test --bin mRustChatd -- --nocapture

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
.PHONY: build build-rust build-rust-release
build: build-rust

build-rust:
	cd rust-cli-chat && cargo build --bin mRustChatd

build-rust-release:
	cd rust-cli-chat && cargo build --bin mRustChatd --release

# ---------------------------------------------------------------------------
# Stop / logs / status
# ---------------------------------------------------------------------------
.PHONY: stop logs status
stop:
	@pkill -f mRustChatd 2>/dev/null && echo "mRustChatd stopped" || true

logs:
	@tail -f $(RUST_LOG)

status:
	@pgrep -a mRustChatd 2>/dev/null || echo "mRustChatd: not running"

# ---------------------------------------------------------------------------
# Swift (suspended — not built or run by default targets)
# ---------------------------------------------------------------------------
build-swift:
	$(SWIFT) build --product mSwiftChatd

build-swift-release:
	$(SWIFT) build --product mSwiftChatd -c release

test-swift:
	$(SWIFT) test
