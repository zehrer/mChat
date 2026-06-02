SWIFT        := $(HOME)/.local/share/swiftly/bin/swift
SWIFT_BIN    := .build/x86_64-unknown-linux-gnu
RUST_BIN     := rust-cli-chat/target
RUST_LOG     := /tmp/mchatd_out.log

# mChatd (Rust) is the primary daemon. mSwiftChatd is archived in Archive/.

# ---------------------------------------------------------------------------
# deploy: release build + restart (primary development loop)
# ---------------------------------------------------------------------------
.PHONY: deploy
deploy: build-rust-release stop
	nohup $(RUST_BIN)/release/mChatd >> $(RUST_LOG) 2>&1 &
	@echo "mChatd restarted. Log: $(RUST_LOG)"

# ---------------------------------------------------------------------------
# test: unit tests
# ---------------------------------------------------------------------------
.PHONY: test test-rust test-rust-verbose
test: test-rust

test-rust:
	cd rust-cli-chat && cargo test --bin mChatd

test-rust-verbose:
	cd rust-cli-chat && cargo test --bin mChatd -- --nocapture

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
.PHONY: build build-rust build-rust-release
build: build-rust

build-rust:
	cd rust-cli-chat && cargo build --bin mChatd

build-rust-release:
	cd rust-cli-chat && cargo build --bin mChatd --release

# ---------------------------------------------------------------------------
# Stop / logs / status
# ---------------------------------------------------------------------------
.PHONY: stop logs status
stop:
	@pkill -f mChatd 2>/dev/null && echo "mChatd stopped" || true

logs:
	@tail -f $(RUST_LOG)

status:
	@pgrep -a mChatd 2>/dev/null || echo "mChatd: not running"

# ---------------------------------------------------------------------------
# Swift tests (mChatCore library — reusable primitives for iOS app)
# ---------------------------------------------------------------------------
test-swift:
	$(SWIFT) test
