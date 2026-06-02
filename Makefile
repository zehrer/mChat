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
.PHONY: test test-verbose
test:
	cargo test -p mChatd

test-verbose:
	cargo test -p mChatd -- --nocapture

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
