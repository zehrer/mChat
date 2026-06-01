SWIFT        := $(HOME)/.local/share/swiftly/bin/swift
SWIFT_BIN    := .build/x86_64-unknown-linux-gnu
RUST_BIN     := rust-cli-chat/target
SWIFT_LOG    := /tmp/swiftd_out.log
RUST_LOG     := /tmp/mchatd_out.log

# ---------------------------------------------------------------------------
# deploy: full release build + restart (primary development loop)
#   make deploy        — build both release binaries and restart daemons
# ---------------------------------------------------------------------------
.PHONY: deploy
deploy: build-release stop
	nohup $(SWIFT_BIN)/release/mSwiftChatd >> $(SWIFT_LOG) 2>&1 &
	nohup $(RUST_BIN)/release/mRustChatd  >> $(RUST_LOG) 2>&1 &
	@echo "Both release daemons restarted. Logs: $(SWIFT_LOG)  $(RUST_LOG)"

# ---------------------------------------------------------------------------
# test: run all unit tests
# ---------------------------------------------------------------------------
.PHONY: test test-swift test-rust test-rust-verbose
test: test-swift test-rust

test-swift:
	$(SWIFT) test

test-rust:
	cd rust-cli-chat && cargo test --bin mRustChatd

test-rust-verbose:
	cd rust-cli-chat && cargo test --bin mRustChatd -- --nocapture

# ---------------------------------------------------------------------------
# Default: debug builds (verbose relay logging, faster compile)
# ---------------------------------------------------------------------------
.PHONY: build build-swift build-rust
build: build-swift build-rust

build-swift:
	$(SWIFT) build --product mSwiftChatd

build-rust:
	cd rust-cli-chat && cargo build --bin mRustChatd

# ---------------------------------------------------------------------------
# Release builds (no debug logging, optimised)
# ---------------------------------------------------------------------------
.PHONY: build-release build-swift-release build-rust-release
build-release: build-swift-release build-rust-release

build-swift-release:
	$(SWIFT) build --product mSwiftChatd -c release

build-rust-release:
	cd rust-cli-chat && cargo build --bin mRustChatd --release

# ---------------------------------------------------------------------------
# Run (debug by default)
# ---------------------------------------------------------------------------
.PHONY: run run-swift run-rust
run: stop run-swift run-rust
	@echo "Both daemons started. Logs: $(SWIFT_LOG)  $(RUST_LOG)"

run-swift: build-swift
	@pkill -f mSwiftChatd 2>/dev/null || true; sleep 0.5
	nohup $(SWIFT_BIN)/debug/mSwiftChatd >> $(SWIFT_LOG) 2>&1 &
	@echo "mSwiftChatd started (debug). Log: $(SWIFT_LOG)"

run-rust: build-rust
	@pkill -f mRustChatd 2>/dev/null || true; sleep 0.5
	nohup $(RUST_BIN)/debug/mRustChatd >> $(RUST_LOG) 2>&1 &
	@echo "mRustChatd started (debug). Log: $(RUST_LOG)"

# ---------------------------------------------------------------------------
# Run release builds
# ---------------------------------------------------------------------------
.PHONY: run-release run-swift-release run-rust-release
run-release: stop run-swift-release run-rust-release
	@echo "Both daemons started (release). Logs: $(SWIFT_LOG)  $(RUST_LOG)"

run-swift-release: build-swift-release
	@pkill -f mSwiftChatd 2>/dev/null || true; sleep 0.5
	nohup $(SWIFT_BIN)/release/mSwiftChatd >> $(SWIFT_LOG) 2>&1 &
	@echo "mSwiftChatd started (release). Log: $(SWIFT_LOG)"

run-rust-release: build-rust-release
	@pkill -f mRustChatd 2>/dev/null || true; sleep 0.5
	nohup $(RUST_BIN)/release/mRustChatd >> $(RUST_LOG) 2>&1 &
	@echo "mRustChatd started (release). Log: $(RUST_LOG)"

# ---------------------------------------------------------------------------
# Stop / logs
# ---------------------------------------------------------------------------
.PHONY: stop logs logs-swift logs-rust status
stop:
	@pkill -f mSwiftChatd 2>/dev/null && echo "mSwiftChatd stopped" || true
	@pkill -f mRustChatd  2>/dev/null && echo "mRustChatd stopped"  || true

logs: logs-swift logs-rust

logs-swift:
	@tail -f $(SWIFT_LOG)

logs-rust:
	@tail -f $(RUST_LOG)

status:
	@pgrep -a mSwiftChatd 2>/dev/null || echo "mSwiftChatd: not running"
	@pgrep -a mRustChatd  2>/dev/null || echo "mRustChatd:  not running"
