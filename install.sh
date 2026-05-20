#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  Akoya Miner — One-line installer & updater for Linux + NVIDIA GPU
#
#  Fresh install:
#    curl -sSL https://get.akoyapool.com/install.sh | sudo bash
#
#  Update to latest:
#    curl -sSL https://get.akoyapool.com/install.sh | sudo bash
#    (same command — it detects an existing install and upgrades in-place)
#
#  Uninstall:
#    akoya-miner uninstall
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR="/opt/akoya-miner"
CONFIG_DIR="/etc/akoya-miner"
ENV_FILE="${CONFIG_DIR}/akoya-miner.env"
LEGACY_CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_NAME="akoya-miner"
WRAPPER_PATH="/usr/local/bin/akoya-miner"
PID_FILE="/var/run/akoya-miner.pid"
LOG_DIR="/var/log/akoya-miner"
LOG_FILE="${LOG_DIR}/miner.log"
STATE_DIR="/var/lib/akoya-miner"
SESSION_FILE="${STATE_DIR}/session.json"
STATS_FILE="/tmp/akoya-miner-stats.json"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://get.akoyapool.com/releases}"
DEFAULT_VERSION="2.0.0"
DEFAULT_POOL_HOST="pool-v2.akoyapool.com"
DEFAULT_POOL_PORT="443"
DEFAULT_WORKER_NAME="worker1"
LATEST_VERSION_URL="${LATEST_VERSION_URL:-${DOWNLOAD_BASE}/latest.txt}"
VERSION="${AKOYA_VERSION:-}"

if [[ -t 1 ]]; then
    BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    RED='\033[0;31m'; CYAN='\033[0;36m'; RESET='\033[0m'
else
    BOLD=''; GREEN=''; YELLOW=''; RED=''; CYAN=''; RESET=''
fi

info()  { echo -e "${GREEN}✓${RESET} $*"; }
warn()  { echo -e "${YELLOW}⚠${RESET} $*"; }
error() { echo -e "${RED}✗${RESET} $*"; }
step()  { echo -e "\n${BOLD}${CYAN}[$1/$TOTAL_STEPS]${RESET} ${BOLD}$2${RESET}"; }

fetch_url() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$url"
    elif command -v wget >/dev/null 2>&1; then wget -qO- "$url"
    else return 127; fi
}

download_file() {
    local url="$1" dest="$2"
    if command -v wget >/dev/null 2>&1; then wget -q --show-progress -O "$dest" "$url"
    elif command -v curl >/dev/null 2>&1; then curl -fSL --progress-bar -o "$dest" "$url"
    else return 127; fi
}

resolve_version() {
    if [[ -n "$VERSION" ]]; then info "Using requested version ${VERSION}"; return 0; fi
    local resolved
    resolved=$(fetch_url "$LATEST_VERSION_URL" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -z "$resolved" || ! "$resolved" =~ ^[0-9]+(\.[0-9]+)*([-.][A-Za-z0-9._-]+)?$ ]]; then
        warn "Could not resolve latest version — falling back to ${DEFAULT_VERSION}"
        VERSION="$DEFAULT_VERSION"
        return 0
    fi
    VERSION="$resolved"
    info "Resolved latest version ${VERSION}"
}

resolve_version

# ── Detect existing install (v1 OR v2) ──────────────────────────────────────
IS_UPGRADE=false
IS_V1_LEGACY=false
OLD_VERSION=""
if [[ -f "$INSTALL_DIR/VERSION" ]]; then
    OLD_VERSION=$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo "unknown")
    IS_UPGRADE=true
    # v1 had a config.json with `pool.url`. v2 uses akoya-miner.env.
    if [[ -f "$LEGACY_CONFIG_FILE" && ! -f "$ENV_FILE" ]]; then
        IS_V1_LEGACY=true
    fi
fi

if $IS_UPGRADE; then TOTAL_STEPS=4; else TOTAL_STEPS=5; fi

if [[ $EUID -ne 0 ]]; then
    error "This installer needs root access (installs to /opt and creates a systemd service)."
    echo "  Please run:  curl -sSL https://get.akoyapool.com/install.sh | sudo bash"
    exit 1
fi

echo ""
if $IS_V1_LEGACY; then
    echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}  ║       Akoya Miner — Migrate v1 → v2.0.0      ║${RESET}"
    echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${RESET}"
    echo ""
    info "v1 install detected (${OLD_VERSION})"
    echo "  Will stop the v1 service, install v2, and migrate your wallet."
elif $IS_UPGRADE; then
    if [[ "$OLD_VERSION" == "$VERSION" ]]; then
        echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${RESET}"
        echo -e "${BOLD}  ║        Akoya Miner — Reinstall / Repair      ║${RESET}"
        echo -e "${BOLD}  ║              v${VERSION}                          ║${RESET}"
        echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${RESET}"
    else
        echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${RESET}"
        echo -e "${BOLD}  ║             Akoya Miner — Update             ║${RESET}"
        echo -e "${BOLD}  ║          ${OLD_VERSION} → ${VERSION}                       ║${RESET}"
        echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${RESET}"
    fi
    echo ""
    info "Existing installation detected — config will be preserved"
else
    echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}  ║             Akoya Miner — Installer          ║${RESET}"
    echo -e "${BOLD}  ║              v${VERSION}                          ║${RESET}"
    echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${RESET}"
fi
echo ""

# ── Step 1: Check NVIDIA driver ─────────────────────────────────────────────
step 1 "Checking your GPU..."

# WSL2: the NVIDIA tooling is shipped by the Windows driver and lives under
# /usr/lib/wsl/lib (not on PATH by default). Surface it so detection works
# without the user having to apt-install anything.
if [[ -x /usr/lib/wsl/lib/nvidia-smi ]] && ! command -v nvidia-smi >/dev/null 2>&1; then
    export PATH="/usr/lib/wsl/lib:$PATH"
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
    error "nvidia-smi not found — NVIDIA driver doesn't seem to be installed."
    if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        echo "  WSL2 detected. Install the latest NVIDIA driver on WINDOWS"
        echo "  (https://www.nvidia.com/Download/index.aspx), then restart WSL"
        echo "    wsl --shutdown   (run in PowerShell)"
        echo "  and re-run this installer. Do NOT apt-install nvidia-driver-* in WSL."
    else
        echo "  Install it (e.g. nvidia-driver-545+) and reboot, then try again."
    fi
    exit 1
fi

cuda_version=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' || true)
if [[ -z "$cuda_version" ]]; then
    error "Could not read CUDA version from nvidia-smi."
    exit 1
fi
cuda_major="${cuda_version%.*}"; cuda_minor="${cuda_version#*.}"
if (( cuda_major < 12 )) || (( cuda_major == 12 && cuda_minor < 4 )); then
    error "Driver supports CUDA $cuda_version, but Pearl needs CUDA 12.4+. Update your driver and reboot."
    exit 1
fi
info "NVIDIA driver OK (CUDA $cuda_version)"

gpu_names=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null || true)
gpu_count=$(echo "$gpu_names" | wc -l)
sm_versions=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits 2>/dev/null | sort -u || true)

unsupported=0
for sm in $sm_versions; do
    sm_int=$(echo "$sm" | tr -d '.')
    (( sm_int < 80 )) && unsupported=1
done
if [[ $unsupported -eq 1 ]]; then
    warn "Some GPUs have compute capability < 8.0 (older than RTX 3060) — they will be skipped."
fi

echo "  Found $gpu_count GPU(s):"
echo "$gpu_names" | while read -r name; do echo "    • $name"; done

# ── Stop any running miner (v1 OR v2) before replacing files ────────────────
stop_existing() {
    if command -v akoya-miner >/dev/null 2>&1; then
        akoya-miner stop 2>/dev/null || true
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    fi
    if [[ -f "$PID_FILE" ]]; then
        local pid; pid=$(cat "$PID_FILE" 2>/dev/null || true)
        [[ -n "${pid:-}" ]] && kill "$pid" 2>/dev/null && sleep 2
        rm -f "$PID_FILE"
    fi
    # Backstop: kill any orphan akoya-miner.bin / akoya-miner process under /opt/akoya-miner
    if command -v pgrep >/dev/null 2>&1; then
        local pids; pids=$(pgrep -f "${INSTALL_DIR}/(akoya-miner|akoya-miner\.bin|Akoya\.Miner)" 2>/dev/null || true)
        for p in $pids; do kill "$p" 2>/dev/null || true; done
        sleep 1
        pids=$(pgrep -f "${INSTALL_DIR}/(akoya-miner|akoya-miner\.bin|Akoya\.Miner)" 2>/dev/null || true)
        for p in $pids; do kill -9 "$p" 2>/dev/null || true; done
    fi
}

if $IS_UPGRADE; then
    stop_existing
    info "Stopped running miner for update"
fi

# Migrate v1 wallet/worker BEFORE we wipe v1 files
MIGRATED_WALLET=""
MIGRATED_WORKER=""
if $IS_V1_LEGACY; then
    if command -v python3 >/dev/null 2>&1; then
        # Use python for robust JSON parsing
        readarray -t MIG < <(python3 -c "
import json, sys
try:
    c = json.load(open('$LEGACY_CONFIG_FILE'))
    p = c.get('pool', {}) if isinstance(c, dict) else {}
    print(p.get('wallet', '') or '')
    print(p.get('worker', '') or '')
except Exception:
    print(''); print('')
" 2>/dev/null) || true
        MIGRATED_WALLET="${MIG[0]:-}"
        MIGRATED_WORKER="${MIG[1]:-}"
    else
        MIGRATED_WALLET=$(grep -oP '"wallet"\s*:\s*"\K[^"]+' "$LEGACY_CONFIG_FILE" 2>/dev/null || true)
        MIGRATED_WORKER=$(grep -oP '"worker"\s*:\s*"\K[^"]+' "$LEGACY_CONFIG_FILE" 2>/dev/null || true)
    fi
    [[ -n "$MIGRATED_WALLET" ]] && info "Migrated wallet from v1 config"
fi

# Wipe v1-only artifacts (binary, lib symlinks, helper scripts) before extracting v2.
# We keep $INSTALL_DIR itself + $CONFIG_DIR + $STATE_DIR (session.json) intact.
if $IS_UPGRADE && [[ -d "$INSTALL_DIR" ]]; then
    rm -f "$INSTALL_DIR/akoya-miner" \
          "$INSTALL_DIR/akoya-miner.bin" \
          "$INSTALL_DIR/Akoya.Miner" \
          "$INSTALL_DIR/detect-gpu.sh" \
          "$INSTALL_DIR/VERSION" \
          "$INSTALL_DIR/README.md" 2>/dev/null || true
    rm -rf "${INSTALL_DIR:?}/lib" 2>/dev/null || true
fi

# ── Step 2: Download ────────────────────────────────────────────────────────
step 2 "Downloading Akoya Miner..."

TARBALL="akoya-miner-${VERSION}-portable.tar.gz"
DOWNLOAD_URL="${DOWNLOAD_BASE}/${VERSION}/${TARBALL}"

mkdir -p "$INSTALL_DIR"

if ! download_file "$DOWNLOAD_URL" "/tmp/$TARBALL"; then
    error "Download failed. URL: $DOWNLOAD_URL"
    exit 1
fi

SHA_URL="${DOWNLOAD_URL}.sha256"
expected_sha=$(curl -sSfL "$SHA_URL" 2>/dev/null | awk '{print $1}' || true)
if [[ -n "$expected_sha" ]]; then
    actual_sha=$(sha256sum "/tmp/$TARBALL" | awk '{print $1}')
    if [[ "$expected_sha" != "$actual_sha" ]]; then
        error "Download verification failed — file may be corrupted."
        echo "  Expected: $expected_sha"
        echo "  Got:      $actual_sha"
        rm -f "/tmp/$TARBALL"
        exit 1
    fi
    info "Download verified (SHA256 OK)"
else
    warn "Could not verify download (SHA256 file not found)"
fi

tar -xzf "/tmp/$TARBALL" -C "$INSTALL_DIR" --strip-components=1
rm -f "/tmp/$TARBALL"

chmod +x "$INSTALL_DIR/akoya-miner" "$INSTALL_DIR/akoya-miner.bin" 2>/dev/null || true

info "Installed to $INSTALL_DIR"

# ── CUDA runtime libs (libcudart.so.12, libcublasLt.so.12) ──────────────────
# The portable GEMM .so dynamically links against the CUDA 12 runtime. On rigs
# with a CUDA toolkit installed system-wide these resolve from /usr/local/cuda
# or via ldconfig. On WSL2 and many minimal Ubuntu images they don't, so we
# fetch a shared sidecar tarball into $INSTALL_DIR/lib/cuda when needed.
have_cuda_libs() {
    local probe="$INSTALL_DIR/lib/libpearl_gemm_capi_portable.so"
    [[ -f "$probe" ]] || return 0
    # Ask the dynamic loader to resolve the .so against the same LD_LIBRARY_PATH
    # the wrapper would set. If both libs resolve, we don't need the sidecar.
    local ld="$INSTALL_DIR/lib"
    [[ -d "$INSTALL_DIR/lib/cuda" ]] && ld="$INSTALL_DIR/lib/cuda:$ld"
    [[ -d /usr/lib/wsl/lib ]] && ld="$ld:/usr/lib/wsl/lib"
    LD_LIBRARY_PATH="$ld" ldd "$probe" 2>/dev/null \
        | grep -E 'libcudart\.so\.12|libcublasLt\.so\.12' \
        | grep -q 'not found' && return 1
    return 0
}

if ! have_cuda_libs; then
    echo "  CUDA 12 runtime libs not found on this system — fetching sidecar..."
    CUDA_TARBALL="cuda-libs-12.9.tar.gz"
    CUDA_URL="${DOWNLOAD_BASE}/${CUDA_TARBALL}"
    if ! download_file "$CUDA_URL" "/tmp/$CUDA_TARBALL"; then
        error "Could not download CUDA libs from $CUDA_URL"
        exit 1
    fi
    cuda_sha=$(curl -sSfL "${CUDA_URL}.sha256" 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$cuda_sha" ]]; then
        actual=$(sha256sum "/tmp/$CUDA_TARBALL" | awk '{print $1}')
        if [[ "$cuda_sha" != "$actual" ]]; then
            error "CUDA libs SHA mismatch (expected $cuda_sha, got $actual)"
            rm -f "/tmp/$CUDA_TARBALL"
            exit 1
        fi
    fi
    mkdir -p "$INSTALL_DIR/lib/cuda"
    tar -xzf "/tmp/$CUDA_TARBALL" -C "$INSTALL_DIR/lib/cuda"
    rm -f "/tmp/$CUDA_TARBALL"
    info "Installed CUDA runtime libs to $INSTALL_DIR/lib/cuda"
    if ! have_cuda_libs; then
        warn "CUDA libs still don't resolve — the miner may fail to start."
        warn "Run: ldd $INSTALL_DIR/lib/libpearl_gemm_capi_portable.so"
    fi
fi

# ── Step 3: Configure (skipped on plain v2 upgrade) ─────────────────────────
CURRENT_STEP=3

mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"

write_env_file() {
    local wallet="$1" worker="$2" host="$3" port="$4" use_tls="$5"
    cat > "$ENV_FILE" <<EOF
# Akoya Miner ${VERSION} — environment file
# Edit this file then \`akoya-miner restart\`. Lines are KEY=value, no quoting required.

AKOYA_POOL_WALLET=${wallet}
AKOYA_POOL_WORKER=${worker}
AKOYA_POOL_HOST=${host}
AKOYA_POOL_PORT=${port}
AKOYA_POOL_USE_TLS=${use_tls}

# Persisted miner identity (don't delete unless you mean to re-register)
AKOYA_SESSION_FILE=${SESSION_FILE}

# HiveOS-style stats sidecar (read by \`akoya-miner status\`)
AKOYA_HIVEOS_STATS_PATH=${STATS_FILE}

# GPU selection: "all" or comma-separated indices like "0,1"
AKOYA_GPU_INDICES=all

# Library paths (the wrapper exports these too; harmless to set explicitly)
AKOYA_PEARL_GEMM_LIB=${INSTALL_DIR}/lib/libpearl_gemm_capi.so
AKOYA_PEARL_MINING_LIB=${INSTALL_DIR}/lib/libpearl_mining_capi.so
EOF
    chmod 600 "$ENV_FILE"
}

if [[ -f "$ENV_FILE" ]] && ! $IS_V1_LEGACY; then
    info "Config preserved at $ENV_FILE"
    wallet_address="(existing config)"
else
    step $CURRENT_STEP "Setting up your miner..."

    if $IS_V1_LEGACY && [[ -n "$MIGRATED_WALLET" ]]; then
        wallet_address="$MIGRATED_WALLET"
        worker_name="${MIGRATED_WORKER:-$DEFAULT_WORKER_NAME}"
        pool_host="$DEFAULT_POOL_HOST"
        pool_port="$DEFAULT_POOL_PORT"
        use_tls="1"
        info "Migrated wallet ${wallet_address}, worker ${worker_name}"
    else
        echo ""
        echo -e "  ${BOLD}You need a Pearl wallet address to receive mining rewards.${RESET}"
        echo "  It starts with 'prl1...' — get one from the Pearl wallet app."
        echo ""

        if [[ -t 0 ]] || [[ -e /dev/tty ]]; then
            read -rp "  Your Pearl wallet address: " wallet_address </dev/tty
            while [[ -z "$wallet_address" ]]; do
                echo -e "  ${RED}Wallet address cannot be empty.${RESET}"
                read -rp "  Your Pearl wallet address: " wallet_address </dev/tty
            done

            read -rp "  Worker name [$DEFAULT_WORKER_NAME]: " worker_name </dev/tty
            worker_name="${worker_name:-$DEFAULT_WORKER_NAME}"

            default_pool="${DEFAULT_POOL_HOST}:${DEFAULT_POOL_PORT}"
            read -rp "  Pool server [$default_pool]: " pool_url </dev/tty
            pool_url="${pool_url:-$default_pool}"
            pool_host="${pool_url%%:*}"
            pool_port="${pool_url##*:}"
            [[ "$pool_host" == "$pool_port" ]] && pool_port="$DEFAULT_POOL_PORT"
            use_tls="1"
        else
            wallet_address="YOUR_WALLET_ADDRESS_HERE"
            worker_name="$DEFAULT_WORKER_NAME"
            pool_host="$DEFAULT_POOL_HOST"
            pool_port="$DEFAULT_POOL_PORT"
            use_tls="1"
            warn "Non-interactive mode — edit $ENV_FILE before starting."
        fi
    fi

    write_env_file "$wallet_address" "$worker_name" "$pool_host" "$pool_port" "$use_tls"
    info "Config written to $ENV_FILE"
fi

# Archive any leftover v1 config so it doesn't confuse future runs.
if $IS_V1_LEGACY && [[ -f "$LEGACY_CONFIG_FILE" ]]; then
    mv "$LEGACY_CONFIG_FILE" "${LEGACY_CONFIG_FILE}.v1.bak" 2>/dev/null || true
    info "Archived v1 config to ${LEGACY_CONFIG_FILE}.v1.bak"
fi

# ── Step N: systemd unit + CLI wrapper ──────────────────────────────────────
CURRENT_STEP=$((CURRENT_STEP + 1))
step $CURRENT_STEP "Setting up auto-start..."

# Remove any stale v1 unit before writing fresh one
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Akoya Miner
After=network-online.target nvidia-persistenced.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_DIR}/akoya-miner mine-blocks
Restart=on-failure
RestartSec=10
Nice=-5

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${INSTALL_DIR} ${LOG_DIR} ${STATE_DIR} /tmp /run

StandardOutput=journal
StandardError=journal
SyslogIdentifier=akoya-miner

SupplementaryGroups=video render

[Install]
WantedBy=multi-user.target
EOF

# Convenience CLI wrapper at /usr/local/bin/akoya-miner.
# (The tarball ships an in-tree wrapper at $INSTALL_DIR/akoya-miner that handles
# GPU detection + LD_LIBRARY_PATH + execs the .bin. This CLI wrapper is a thin
# control layer on top: start/stop/status/logs/config/version/uninstall.)
cat > "$WRAPPER_PATH" <<WRAPPER
#!/usr/bin/env bash
# akoya-miner — convenience CLI (works with systemd or PID-file)
set -euo pipefail

SERVICE="${SERVICE_NAME}"
INSTALL="${INSTALL_DIR}"
ENV_FILE="${ENV_FILE}"
PIDFILE="${PID_FILE}"
LOGFILE="${LOG_FILE}"
STATS_FILE="${STATS_FILE}"

WRAPPER

# (the heredoc above closed; everything below is double-quoted-then-literal blocks
# concatenated to keep variable expansion clean. Append the rest verbatim.)
cat >> "$WRAPPER_PATH" <<'WRAPPER'
has_systemd() { [[ -d /run/systemd/system ]]; }
has_unit()    { [[ -f "/etc/systemd/system/${SERVICE}.service" ]]; }

is_running() {
    if has_systemd && has_unit; then
        systemctl is-active --quiet "$SERVICE" 2>/dev/null && return 0
    fi
    if [[ -f "$PIDFILE" ]]; then
        local pid; pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
    fi
    if [[ -x "$INSTALL/akoya-miner.bin" ]]; then
        pgrep -f "$INSTALL/akoya-miner\.bin" >/dev/null 2>&1 && return 0
    fi
    return 1
}

load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
    fi
}

do_start() {
    if is_running; then echo "✓ Akoya Miner is already running"; return 0; fi
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "✗ No config at $ENV_FILE — run: akoya-miner config"
        return 1
    fi
    if has_systemd && has_unit; then
        sudo systemctl start "$SERVICE"
    else
        mkdir -p "$(dirname "$LOGFILE")" "$(dirname "$PIDFILE")"
        load_env
        echo "  Starting Akoya Miner (logging to $LOGFILE)..."
        nohup "$INSTALL/akoya-miner" mine-blocks >> "$LOGFILE" 2>&1 &
        echo $! > "$PIDFILE"
    fi
    sleep 2
    if is_running; then
        echo "✓ Akoya Miner started"
        echo "  View logs: akoya-miner log"
    else
        echo "✗ Akoya Miner failed to start — check: akoya-miner log"
        return 1
    fi
}

do_stop() {
    if ! is_running; then echo "Akoya Miner is not running"; return 0; fi
    local stopped=0
    if has_systemd && has_unit && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        sudo systemctl stop "$SERVICE" && stopped=1
    fi
    if [[ -f "$PIDFILE" ]]; then
        local pid; pid=$(cat "$PIDFILE" 2>/dev/null || true)
        if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
            stopped=1
        fi
        rm -f "$PIDFILE" 2>/dev/null || sudo rm -f "$PIDFILE" 2>/dev/null || true
    fi
    if [[ -x "$INSTALL/akoya-miner.bin" ]]; then
        local pids; pids=$(pgrep -f "$INSTALL/akoya-miner\.bin" 2>/dev/null || true)
        for p in $pids; do kill "$p" 2>/dev/null || sudo kill "$p" 2>/dev/null || true; done
        sleep 1
        pids=$(pgrep -f "$INSTALL/akoya-miner\.bin" 2>/dev/null || true)
        for p in $pids; do kill -9 "$p" 2>/dev/null || sudo kill -9 "$p" 2>/dev/null || true; done
        [[ -n "${pids:-}" ]] && stopped=1
    fi
    if [[ "$stopped" == "1" ]]; then echo "✓ Akoya Miner stopped"
    else echo "Akoya Miner was not running"; fi
}

case "${1:-status}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; do_start ;;
    status)
        if is_running; then
            echo "✓ Akoya Miner is running"
            [[ -f "$PIDFILE" ]] && ! has_systemd && echo "  PID: $(cat "$PIDFILE")"
        else
            echo "✗ Akoya Miner is not running"
        fi
        echo ""
        if [[ -f "$STATS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
            python3 -c "
import json, time, os
try:
    s = json.load(open('$STATS_FILE'))
    sh = s.get('shares', {})
    gpus = s.get('gpus', [])
    up_h = s.get('uptime_seconds', 0) / 3600
    age = time.time() - os.path.getmtime('$STATS_FILE')
    stale = ' (stale — last updated {:.0f}s ago)'.format(age) if age > 30 else ''
    print(f'  Uptime:    {up_h:.1f} hours{stale}')
    print(f'  Shares:    {sh.get(\"accepted\", 0)} accepted, {sh.get(\"rejected\", 0)} rejected')
    print(f'  GPUs:      {len(gpus)}')
    for g in gpus:
        print(f'    GPU {g[\"index\"]}: {g.get(\"temp_c\", \"?\")}°C  {g.get(\"fan_pct\", \"?\")}% fan  {g.get(\"power_w\", \"?\")}W')
except Exception:
    pass
"
        elif [[ ! -f "$STATS_FILE" ]]; then
            echo "  (no stats yet — miner may still be starting)"
        fi
        ;;
    log|logs)
        if has_systemd; then journalctl -u "$SERVICE" -f --no-pager -n 50
        elif [[ -f "$LOGFILE" ]]; then tail -f -n 50 "$LOGFILE"
        else echo "No log file at $LOGFILE — start the miner first: akoya-miner start"; fi
        ;;
    config)
        if [[ ! -f "$ENV_FILE" ]]; then
            echo "✗ No config file. Re-run the installer."
            exit 1
        fi
        if [[ -t 0 ]]; then
            ${EDITOR:-nano} "$ENV_FILE"
            echo ""; echo "Config saved. Run 'akoya-miner restart' to apply."
        else
            cat "$ENV_FILE"
        fi
        ;;
    uninstall)
        echo "Uninstalling Akoya Miner..."
        do_stop 2>/dev/null || true
        if has_systemd; then
            sudo systemctl disable "$SERVICE" 2>/dev/null || true
            sudo rm -f "/etc/systemd/system/${SERVICE}.service"
            sudo systemctl daemon-reload
        fi
        sudo rm -rf "$INSTALL"
        sudo rm -rf /etc/akoya-miner /var/lib/akoya-miner /var/log/akoya-miner
        sudo rm -f "$PIDFILE" "$STATS_FILE"
        sudo rm -f /usr/local/bin/akoya-miner
        echo "✓ Akoya Miner uninstalled"
        ;;
    version)
        "$INSTALL/akoya-miner" version 2>/dev/null \
            || echo "akoya-miner v$(cat "$INSTALL/VERSION" 2>/dev/null || echo unknown)"
        ;;
    help|--help|-h)
        cat <<USAGE
Akoya Miner

Usage: akoya-miner <command>

Commands:
  start      Start mining
  stop       Stop mining
  restart    Restart the miner
  status     Show miner status and GPU stats
  log        Follow live miner logs
  config     Edit your wallet/pool settings
  version    Show miner version
  uninstall  Remove Akoya Miner from this system

Config file: $ENV_FILE
USAGE
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'akoya-miner help' for usage."
        exit 1
        ;;
esac
WRAPPER

chmod +x "$WRAPPER_PATH"

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    info "Systemd service installed (starts on boot)"
else
    info "Wrapper installed (no systemd — use 'akoya-miner start/stop')"
fi

# ── Final step: Start mining! ───────────────────────────────────────────────
CURRENT_STEP=$((CURRENT_STEP + 1))
step $CURRENT_STEP "Starting the miner..."

if grep -q '^AKOYA_POOL_WALLET=YOUR_WALLET_ADDRESS_HERE' "$ENV_FILE" 2>/dev/null; then
    warn "Placeholder wallet — edit your config first:"
    echo ""
    echo "  akoya-miner config"
    echo "  akoya-miner start"
else
    "$WRAPPER_PATH" start 2>/dev/null || {
        warn "Miner may have failed to start. Check logs:"
        echo "  akoya-miner log"
    }
fi

echo ""
if $IS_V1_LEGACY; then
    echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}  ║          ✓ Migrated to v${VERSION}!                ║${RESET}"
    echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${RESET}"
elif $IS_UPGRADE; then
    if [[ "$OLD_VERSION" == "$VERSION" ]]; then
        echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${RESET}"
        echo -e "${BOLD}  ║          ✓ Reinstall complete!               ║${RESET}"
        echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${RESET}"
    else
        echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${RESET}"
        echo -e "${BOLD}  ║          ✓ Update complete!                  ║${RESET}"
        echo -e "${BOLD}  ║          ${OLD_VERSION} → ${VERSION}                       ║${RESET}"
        echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${RESET}"
    fi
else
    echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}  ║          ✓ Installation complete!            ║${RESET}"
    echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${RESET}"
fi
echo ""
echo "  Useful commands:"
echo "    akoya-miner status   — show miner status & GPU stats"
echo "    akoya-miner log      — follow live logs"
echo "    akoya-miner config   — edit wallet/pool"
echo "    akoya-miner restart  — apply config changes"
echo ""
