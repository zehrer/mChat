BIN      := target/release/mChatd
LOG      := /tmp/mchatd_out.log

# ---------------------------------------------------------------------------
# deploy: release build + restart
# ---------------------------------------------------------------------------
.PHONY: deploy
deploy: build-release stop
	nohup $(BIN) >> $(LOG) 2>&1 &
	@echo "mChatd restarted. Log: $(LOG)"

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
	@pkill -f mChatd 2>/dev/null && echo "mChatd stopped" || true

logs:
	@tail -f $(LOG)

status:
	@pgrep -a mChatd 2>/dev/null || echo "mChatd: not running"
