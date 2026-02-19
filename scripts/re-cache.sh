#!/usr/bin/env bash
#
# Manage a local REAPI cache server for Buck2.
#
# Usage:
#   ./scripts/re-cache.sh start    # start bazel-remote in a container
#   ./scripts/re-cache.sh stop     # stop the container
#   ./scripts/re-cache.sh status   # show container and cache status
#   ./scripts/re-cache.sh enable   # write .buckconfig.local to use the cache
#   ./scripts/re-cache.sh disable  # revert .buckconfig.local to local execution
#   ./scripts/re-cache.sh purge    # stop server and delete all cache data

set -euo pipefail

CACHE_DIR="$HOME/.cache/buckos/re-cache"
CONTAINER_NAME="buckos-re-cache"
GRPC_PORT=9092
IMAGE="docker.io/buchgr/bazel-remote-cache"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUCKCONFIG_LOCAL="$REPO_ROOT/.buckconfig.local"

# Detect container runtime (prefer podman)
if command -v podman &>/dev/null; then
    RUNTIME=podman
elif command -v docker &>/dev/null; then
    RUNTIME=docker
else
    echo "Error: neither podman nor docker found" >&2
    exit 1
fi

cmd_start() {
    if $RUNTIME ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        echo "Already running: $CONTAINER_NAME"
        return 0
    fi

    # Remove stopped container if it exists
    $RUNTIME rm -f "$CONTAINER_NAME" &>/dev/null || true

    mkdir -p "$CACHE_DIR"

    echo "Starting $CONTAINER_NAME (gRPC :${GRPC_PORT})..."
    $RUNTIME run -d \
        --name "$CONTAINER_NAME" \
        --network=host \
        -v "$CACHE_DIR:/data" \
        "$IMAGE" \
        --dir=/data \
        --max_size=50 \
        --storage_mode=uncompressed \
        --enable_endpoint_metrics=false \
        --grpc_address=0.0.0.0:9092 \
        --http_address=0.0.0.0:8092 \
        --max_blob_size=1073741824

    echo "Started. Cache dir: $CACHE_DIR"
}

cmd_stop() {
    if $RUNTIME ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        echo "Stopping $CONTAINER_NAME..."
        $RUNTIME stop "$CONTAINER_NAME" &>/dev/null
        $RUNTIME rm "$CONTAINER_NAME" &>/dev/null || true
        echo "Stopped."
    else
        echo "Not running."
        $RUNTIME rm "$CONTAINER_NAME" &>/dev/null || true
    fi
}

cmd_status() {
    if $RUNTIME ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        echo "Server: running (gRPC :${GRPC_PORT})"
    else
        echo "Server: stopped"
    fi

    if [[ -d "$CACHE_DIR" ]]; then
        local size
        size="$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)"
        echo "Cache:  $CACHE_DIR ($size)"
    else
        echo "Cache:  (empty)"
    fi

    if [[ -f "$BUCKCONFIG_LOCAL" ]] && grep -q "execution:cached" "$BUCKCONFIG_LOCAL" 2>/dev/null; then
        echo "Config: enabled (.buckconfig.local)"
    else
        echo "Config: disabled"
    fi
}

cmd_enable() {
    cat > "$BUCKCONFIG_LOCAL" <<'EOF'
[buck2_re_client]
  engine_address = grpc://localhost:9092
  action_cache_address = grpc://localhost:9092
  cas_address = grpc://localhost:9092
  tls = false
  instance_name = buckos

[build]
  execution_platforms = root//platforms/execution:cached

[buck2]
  digest_algorithms = SHA256
EOF
    echo "Wrote $BUCKCONFIG_LOCAL (cache enabled)"
    echo "Run 'buck2 kill' to pick up the new config."
}

cmd_disable() {
    rm -f "$BUCKCONFIG_LOCAL"
    echo "Removed $BUCKCONFIG_LOCAL (cache disabled)"
    echo "Run 'buck2 kill' to pick up the new config."
}

cmd_purge() {
    cmd_stop
    if [[ -d "$CACHE_DIR" ]]; then
        echo "Deleting $CACHE_DIR..."
        rm -rf "$CACHE_DIR"
        echo "Purged."
    fi
}

usage() {
    echo "Usage: $0 {start|stop|status|enable|disable|purge}"
    exit 1
}

case "${1:-}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    enable)  cmd_enable ;;
    disable) cmd_disable ;;
    purge)   cmd_purge ;;
    *)       usage ;;
esac
