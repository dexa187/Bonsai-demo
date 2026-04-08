#!/bin/sh
# Start an OpenAI-compatible chat server with the Bonsai model.
# Usage: ./scripts/start_llama_server.sh
# Then open http://localhost:8080 in your browser.
#
# By default a small Python proxy fixes common client JSON bugs (null
# "content" / "reasoning_content" / tool fields) that cause 500s on
# /v1/chat/completions. Disable with: BONSAI_OPENAI_SANITIZE=0
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"
assert_valid_model
DEMO_DIR="$(resolve_demo_dir)"
cd "$DEMO_DIR"
assert_gguf_downloaded

HOST="0.0.0.0"
PORT=8080
INTERNAL_PORT="${BONSAI_LLAMA_INTERNAL_PORT:-18080}"
SANITIZE="${BONSAI_OPENAI_SANITIZE:-1}"

# ── Resolve Python (for optional OpenAI request sanitizer proxy) ──
PY=""
if [ -x "$DEMO_DIR/.venv/bin/python" ]; then
    PY="$DEMO_DIR/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
    PY="python3"
fi

# ── Check ports ──
if curl -s --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    warn "Something already answers /health on port $PORT."
    echo "  Stop it first with:  kill \$(lsof -ti TCP:$PORT)"
    exit 1
fi
if [ "$SANITIZE" != "0" ] && [ -n "$PY" ]; then
    if curl -s --max-time 2 "http://127.0.0.1:$INTERNAL_PORT/health" >/dev/null 2>&1; then
        err "Port $INTERNAL_PORT is in use (needed for llama-server when sanitizer proxy is on)."
        echo "  Set BONSAI_LLAMA_INTERNAL_PORT to a free port, or stop the other service."
        exit 1
    fi
fi

# ── Find model ──
MODEL=""
for _m in $GGUF_MODEL_DIR/*.gguf; do
    [ -f "$_m" ] && MODEL="$DEMO_DIR/$_m" && break
done

# ── Find binary (search all known locations) ──
BIN=""
for _d in bin/mac bin/cuda bin/rocm bin/hip llama.cpp/build/bin llama.cpp/build-mac/bin llama.cpp/build-cuda/bin; do
    [ -f "$DEMO_DIR/$_d/llama-server" ] && BIN="$DEMO_DIR/$_d/llama-server" && break
done
if [ -z "$BIN" ]; then
    err "llama-server not found. Run ./setup.sh or ./scripts/download_binaries.sh first."
    exit 1
fi

BIN_DIR="$(cd "$(dirname "$BIN")" && pwd)"
export LD_LIBRARY_PATH="$BIN_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo ""
echo "=== llama.cpp server (GGUF) ==="
echo "  Model:   $(basename "$MODEL")"
echo "  Binary:  $BIN"
echo "  Context: auto-fit (-c 0)"
if [ "$SANITIZE" != "0" ] && [ -n "$PY" ]; then
    echo "  Sanitizer proxy:  on → public port $PORT, llama on 127.0.0.1:$INTERNAL_PORT"
    echo "    (disable with BONSAI_OPENAI_SANITIZE=0)"
else
    echo "  Sanitizer proxy:  off"
fi
echo ""
echo "  Open http://localhost:$PORT in your browser to chat."
echo "  API:  http://localhost:$PORT/v1/chat/completions"
echo "  Press Ctrl+C to stop."
echo ""

if [ "$SANITIZE" != "0" ] && [ -n "$PY" ]; then
    cleanup() {
        [ -n "${LLAMA_PID:-}" ] && kill "$LLAMA_PID" 2>/dev/null || true
    }
    trap cleanup INT TERM EXIT

    "$BIN" -m "$MODEL" --host 127.0.0.1 --port "$INTERNAL_PORT" -ngl 99 -c "$CTX_SIZE_DEFAULT" \
        --temp 0.5 --top-p 0.85 --top-k 20 --min-p 0 \
        --reasoning-budget 0 --reasoning-format none \
        --chat-template-kwargs '{"enable_thinking": false}' \
        "$@" &
    LLAMA_PID=$!

    _n=0
    while [ "$_n" -lt 90 ]; do
        if curl -s --max-time 2 "http://127.0.0.1:$INTERNAL_PORT/health" >/dev/null 2>&1; then
            break
        fi
        _n=$((_n + 1))
        sleep 1
    done
    if ! curl -s --max-time 2 "http://127.0.0.1:$INTERNAL_PORT/health" >/dev/null 2>&1; then
        err "llama-server did not become healthy on 127.0.0.1:$INTERNAL_PORT"
        exit 1
    fi

    "$PY" "$SCRIPT_DIR/openai_chat_proxy.py" --host "$HOST" --port "$PORT" \
        --backend "http://127.0.0.1:$INTERNAL_PORT"
    exit 0
fi

if [ "$SANITIZE" != "0" ] && [ -z "$PY" ]; then
    warn "python3 not found — cannot run sanitizer; starting llama-server alone (set BONSAI_OPENAI_SANITIZE=0 to silence)."
fi

exec "$BIN" -m "$MODEL" --host "$HOST" --port "$PORT" -ngl 99 -c "$CTX_SIZE_DEFAULT" \
    --temp 0.5 --top-p 0.85 --top-k 20 --min-p 0 \
    --reasoning-budget 0 --reasoning-format none \
    --chat-template-kwargs '{"enable_thinking": false}' \
    "$@"
