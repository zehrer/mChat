BIN      := target/release/mChatd
LOG      := /tmp/mchatd_out.log
PID      := /tmp/mchatd.pid

# ---------------------------------------------------------------------------
# deploy: release build + restart
# ---------------------------------------------------------------------------
.PHONY: deploy
deploy: build-release stop
	nohup $(BIN) >> $(LOG) 2>&1 & echo $$! > $(PID)
	@echo "mChatd restarted (pid $$(cat $(PID))). Log: $(LOG)"

# ---------------------------------------------------------------------------
# test
# ---------------------------------------------------------------------------
.PHONY: test test-verbose test-integration
test:
	cargo test -p mChatd

test-verbose:
	cargo test -p mChatd -- --nocapture

test-integration:
	@echo "Building mCLIChat…"
	@cargo build -p mCLIChat 2>&1 | tail -1
	@echo "Running integration tests against live mChatd…"
	mCLIChat/tests/integration_test.sh

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
.PHONY: build build-release
build:
	cargo build -p mChatd

build-release:
	cargo build -p mChatd --release

# ---------------------------------------------------------------------------
# stop / logs / status
# ---------------------------------------------------------------------------
.PHONY: stop logs status
stop:
	@pkill -x mChatd 2>/dev/null && echo "mChatd stopped" || echo "mChatd: not running"
	@rm -f $(PID)
	@pkill -x mRustChatd 2>/dev/null && echo "WARNING: stray mRustChatd stopped" || true

logs:
	@tail -f $(LOG)

status:
	@pgrep -a mChatd 2>/dev/null || echo "mChatd: not running"
	@if pgrep -x mRustChatd > /dev/null 2>&1; then echo "WARNING: stray mRustChatd is running — run 'make stop' to kill it"; fi
