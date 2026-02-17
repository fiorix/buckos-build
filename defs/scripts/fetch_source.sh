#!/bin/bash
# Configurable multi-source download with mirror support
#
# Arguments:
#   $1 - Output file path
#   $2 - Upstream URL (original src_uri)
#   $3 - Expected SHA256 checksum
#
# Configuration via environment variables:
#   BUCKOS_SOURCE_ORDER              - Comma-separated source backends (default: "vendor,buckos-mirror,upstream")
#   BUCKOS_MIRROR_URL                - Public BuckOS mirror base URL
#   BUCKOS_VENDOR_DIR                - Vendor directory path (default: "vendor")
#   BUCKOS_VENDOR_PREFER             - Whether to check vendor first (default: "true")
#   BUCKOS_VENDOR_REQUIRE            - Require vendored sources, fail if missing (default: "false")
#   BUCKOS_DOWNLOAD_PROXY            - HTTP proxy URL for curl
#   BUCKOS_INTERNAL_MIRROR_TYPE      - "http" or "cli"
#   BUCKOS_INTERNAL_MIRROR_BASE_URL  - Base URL for HTTP mode (files at {base}/{l}/{file})
#   BUCKOS_INTERNAL_MIRROR_CERT_PATH - x509 cert path for HTTP mode (optional)
#   BUCKOS_INTERNAL_MIRROR_CLI_GET   - CLI get command template (use {path} and {output} placeholders)
#   BUCKOS_MAX_CONCURRENT_DOWNLOADS  - Concurrent download limit (default: 4)

set -e

OUT_FILE="$1"
URL="$2"
EXPECTED_SHA256="$3"

if [ -z "$OUT_FILE" ] || [ -z "$URL" ] || [ -z "$EXPECTED_SHA256" ]; then
    echo "Usage: fetch_source.sh <output-file> <upstream-url> <sha256>" >&2
    exit 1
fi

# Derive filename and first-letter prefix from output file
FILENAME="$(basename "$OUT_FILE")"
FIRST_LETTER="$(echo "$FILENAME" | head -c1 | tr '[:upper:]' '[:lower:]')"

# Configuration defaults
SOURCE_ORDER="${BUCKOS_SOURCE_ORDER:-vendor,buckos-mirror,upstream}"
MIRROR_URL="${BUCKOS_MIRROR_URL:-}"
VENDOR_DIR="${BUCKOS_VENDOR_DIR:-vendor}"
VENDOR_PREFER="${BUCKOS_VENDOR_PREFER:-true}"
VENDOR_REQUIRE="${BUCKOS_VENDOR_REQUIRE:-false}"
DOWNLOAD_PROXY="${BUCKOS_DOWNLOAD_PROXY:-}"

# Build curl proxy args
PROXY_ARGS=""
if [ -n "$DOWNLOAD_PROXY" ]; then
    PROXY_ARGS="--proxy $DOWNLOAD_PROXY"
fi

# ============================================================================
# Concurrent download limiting (flock-based semaphore)
# ============================================================================

MAX_CONCURRENT_DOWNLOADS="${BUCKOS_MAX_CONCURRENT_DOWNLOADS:-4}"
LOCK_DIR="${BUCKOS_DOWNLOAD_LOCK_DIR:-/tmp/buckos-download-locks}"

acquire_download_slot() {
    if ! command -v flock &>/dev/null; then
        return 0
    fi

    mkdir -p "$LOCK_DIR"

    # Try to acquire any available slot from the pool
    for i in $(seq 0 $((MAX_CONCURRENT_DOWNLOADS - 1))); do
        LOCK_FILE="$LOCK_DIR/download-slot-$i.lock"
        exec {LOCK_FD}>>"$LOCK_FILE"
        if flock -n "$LOCK_FD" 2>/dev/null; then
            export BUCKOS_DOWNLOAD_LOCK_FD="$LOCK_FD"
            export BUCKOS_DOWNLOAD_LOCK_FILE="$LOCK_FILE"
            return 0
        fi
        exec {LOCK_FD}>&-
    done

    # All slots busy, wait for any slot to become available
    for i in $(seq 0 $((MAX_CONCURRENT_DOWNLOADS - 1))); do
        LOCK_FILE="$LOCK_DIR/download-slot-$i.lock"
        exec {LOCK_FD}>>"$LOCK_FILE"
        if flock "$LOCK_FD" 2>/dev/null; then
            export BUCKOS_DOWNLOAD_LOCK_FD="$LOCK_FD"
            export BUCKOS_DOWNLOAD_LOCK_FILE="$LOCK_FILE"
            return 0
        fi
        exec {LOCK_FD}>&-
    done

    # Fallback: proceed without lock
    return 0
}

release_download_slot() {
    if [ -n "${BUCKOS_DOWNLOAD_LOCK_FD:-}" ]; then
        flock -u "$BUCKOS_DOWNLOAD_LOCK_FD" 2>/dev/null || true
        exec {BUCKOS_DOWNLOAD_LOCK_FD}>&- 2>/dev/null || true
    fi
}

trap release_download_slot EXIT

# ============================================================================
# SHA256 verification
# ============================================================================

verify_sha256() {
    local file="$1"
    local expected="$2"
    if [ -n "$expected" ]; then
        local actual
        actual=$(sha256sum "$file" | cut -d' ' -f1)
        if [ "$actual" != "$expected" ]; then
            echo "  SHA256 mismatch: expected=$expected actual=$actual" >&2
            return 1
        fi
    fi
    return 0
}

# ============================================================================
# Find repo root
# ============================================================================

REPO_ROOT="$PWD"
while [ ! -f "$REPO_ROOT/.buckconfig" ] && [ "$REPO_ROOT" != "/" ]; do
    REPO_ROOT="$(dirname "$REPO_ROOT")"
done

# ============================================================================
# Source backend functions
# ============================================================================

try_vendor() {
    if [ "$VENDOR_PREFER" != "true" ]; then
        return 1
    fi

    local vendor_path="$REPO_ROOT/$VENDOR_DIR/$FIRST_LETTER/$FILENAME"

    # Try exact path first
    if [ -f "$vendor_path" ]; then
        echo "Found vendored source: $vendor_path"
        if verify_sha256 "$vendor_path" "$EXPECTED_SHA256"; then
            echo "SHA256 verified, using vendored source"
            cp "$vendor_path" "$OUT_FILE"
            return 0
        else
            echo "WARNING: Vendored source checksum mismatch, skipping"
        fi
    fi

    # Scan vendor directory for SHA256 match (filename may differ from URL)
    local scan_dir="$REPO_ROOT/$VENDOR_DIR"
    if [ -d "$scan_dir" ] && [ -n "$EXPECTED_SHA256" ]; then
        for f in "$scan_dir"/*/"$(basename "$vendor_path")" "$scan_dir"/*/*; do
            if [ -f "$f" ]; then
                if verify_sha256 "$f" "$EXPECTED_SHA256" 2>/dev/null; then
                    echo "Found vendored source by SHA256 match: $f"
                    cp "$f" "$OUT_FILE"
                    return 0
                fi
            fi
        done 2>/dev/null || true
    fi

    return 1
}

try_buckos_mirror() {
    if [ -z "$MIRROR_URL" ]; then
        return 1
    fi

    local mirror_file_url="${MIRROR_URL}/${FIRST_LETTER}/${FILENAME}"
    echo "Trying BuckOS mirror: $mirror_file_url"

    acquire_download_slot

    if curl -fsSL --connect-timeout 10 --max-time 300 --retry 1 $PROXY_ARGS -o "$OUT_FILE" "$mirror_file_url" 2>/dev/null; then
        if [ -s "$OUT_FILE" ] && verify_sha256 "$OUT_FILE" "$EXPECTED_SHA256"; then
            echo "Downloaded from BuckOS mirror, SHA256 verified"
            release_download_slot
            return 0
        fi
        rm -f "$OUT_FILE"
    fi

    release_download_slot
    return 1
}

try_internal_mirror() {
    local mirror_type="${BUCKOS_INTERNAL_MIRROR_TYPE:-}"
    if [ -z "$mirror_type" ]; then
        return 1
    fi

    local mirror_path="${FIRST_LETTER}/${FILENAME}"

    echo "Trying internal mirror ($mirror_type): $mirror_path"

    acquire_download_slot

    if [ "$mirror_type" = "http" ]; then
        local base_url="${BUCKOS_INTERNAL_MIRROR_BASE_URL:-}"
        if [ -z "$base_url" ]; then
            echo "WARNING: internal mirror type=http but no base URL configured" >&2
            release_download_slot
            return 1
        fi

        local cert_path="${BUCKOS_INTERNAL_MIRROR_CERT_PATH:-}"
        local cert_args=""
        if [ -n "$cert_path" ]; then
            cert_args="--cert $cert_path"
        fi

        if curl -fsSL --connect-timeout 10 --max-time 300 $cert_args $PROXY_ARGS \
            -o "$OUT_FILE" "${base_url}/${mirror_path}" 2>/dev/null; then
            if [ -s "$OUT_FILE" ] && verify_sha256 "$OUT_FILE" "$EXPECTED_SHA256"; then
                echo "Downloaded from internal mirror (HTTP), SHA256 verified"
                release_download_slot
                return 0
            fi
            rm -f "$OUT_FILE"
        fi
    elif [ "$mirror_type" = "cli" ]; then
        # CLI mode: BUCKOS_INTERNAL_MIRROR_CLI_GET is a command template
        # Placeholders: {path} = mirror_path, {output} = output file
        local cli_get="${BUCKOS_INTERNAL_MIRROR_CLI_GET:-}"
        if [ -z "$cli_get" ]; then
            echo "WARNING: internal mirror type=cli but no CLI get command configured" >&2
            release_download_slot
            return 1
        fi

        local cmd="${cli_get//\{path\}/$mirror_path}"
        cmd="${cmd//\{output\}/$OUT_FILE}"

        if eval "$cmd" >/dev/null 2>&1; then
            if [ -s "$OUT_FILE" ] && verify_sha256 "$OUT_FILE" "$EXPECTED_SHA256"; then
                echo "Downloaded from internal mirror (CLI), SHA256 verified"
                release_download_slot
                return 0
            fi
            rm -f "$OUT_FILE"
        fi
    else
        echo "WARNING: Unknown internal mirror type: $mirror_type" >&2
    fi

    release_download_slot
    return 1
}

try_upstream() {
    echo "Trying upstream: $URL"

    acquire_download_slot

    if curl -fsSL --connect-timeout 10 --max-time 300 --retry 1 $PROXY_ARGS -o "$OUT_FILE" "$URL" 2>/dev/null; then
        if [ -s "$OUT_FILE" ]; then
            if verify_sha256 "$OUT_FILE" "$EXPECTED_SHA256"; then
                echo "Downloaded from upstream, SHA256 verified"
                release_download_slot
                return 0
            else
                echo "WARNING: Upstream download SHA256 mismatch"
                rm -f "$OUT_FILE"
            fi
        fi
    fi

    release_download_slot
    return 1
}

# ============================================================================
# Main: iterate source order
# ============================================================================

# Check vendor_require early — if set and vendor fails, we should not try other sources
TRIED_VENDOR=false

IFS=',' read -ra SOURCES <<< "$SOURCE_ORDER"
for source in "${SOURCES[@]}"; do
    # Trim whitespace
    source="$(echo "$source" | tr -d ' ')"

    case "$source" in
        vendor)
            TRIED_VENDOR=true
            if try_vendor; then
                exit 0
            fi
            ;;
        buckos-mirror)
            if try_buckos_mirror; then
                exit 0
            fi
            ;;
        internal-mirror)
            if try_internal_mirror; then
                exit 0
            fi
            ;;
        upstream)
            if try_upstream; then
                exit 0
            fi
            ;;
        *)
            echo "WARNING: Unknown source backend: $source" >&2
            ;;
    esac
done

# If vendor is required and we tried it (or it wasn't in the list), fail
if [ "$VENDOR_REQUIRE" = "true" ]; then
    echo "ERROR: Vendored source required but not found or invalid" >&2
    echo "  Filename: $FILENAME" >&2
    echo "  Vendor path: $VENDOR_DIR/$FIRST_LETTER/$FILENAME" >&2
    echo "  Run: ./tools/vendor-sources --target <target> to vendor sources" >&2
    exit 1
fi

echo "ERROR: Could not download $FILENAME from any source" >&2
echo "  URL: $URL" >&2
echo "  Sources tried: $SOURCE_ORDER" >&2
exit 1
