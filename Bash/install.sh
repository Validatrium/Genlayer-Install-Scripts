#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# GenLayer installer + key backup automation
# Ubuntu/Debian; run as root.
# =========================

# ---- Defaults (override via flags or env) ----
VERSION="${VERSION:-}"                       # e.g. v0.3.10; empty = auto-latest
ZKSYNC_HTTP="${ZKSYNC_HTTP:-}"
ZKSYNC_WS="${ZKSYNC_WS:-}"
HEURISTKEY="${HEURISTKEY:-}"
COMPUT3KEY="${COMPUT3KEY:-}"
IOINTELLIGENCE_API_KEY="${IOINTELLIGENCE_API_KEY:-}"

INSTALL_ROOT="/opt/genlayer"
DATA_DIR="/var/lib/genlayer"
CONF_DIR="${INSTALL_ROOT}/current/configs/node"
ENV_DIR="/etc/genlayer"
ENV_FILE="${ENV_DIR}/genlayer.env"
SECRETS_DIR="${ENV_DIR}/secret"
PASSWORD_FILE="${SECRETS_DIR}/node_password"
BACKUP_PASSPHRASE_FILE="${SECRETS_DIR}/backup_passphrase"
ADDR_FILE="${ENV_DIR}/validator.address"
BACKUP_DIR="/var/backups/genlayer"
SERVICE_NAME="genlayernode.service"

# Consensus addresses (required)
CONSENSUS_MAIN="0xe30293d600fF9B2C865d91307826F28006A458f4"
CONSENSUS_DATA="0x2a50afD9d3E0ACC824aC4850d7B4c5561aB5D27a"
GENESIS_BLOCK="817855"

NONINTERACTIVE=0
PW_SUPPLIED=0
BPW_SUPPLIED=0

usage() {
  cat <<'EOF'
Usage: sudo ./install-genlayer.sh [options]

Options:
  -v, --version <vX.Y.Z>     Pin node version (default: auto-detect latest)
  --zksync-http <URL>        ZKSync HTTP RPC URL
  --zksync-ws <URL>          ZKSync WebSocket RPC URL
  --password-file <path>     File with node account password (one line)
  --backup-pass-file <path>  File with backup encryption passphrase (one line)
  --non-interactive          Do not prompt; fail if required inputs missing
  -h, --help                 Show this help

Env alternatives:
  ZKSYNC_HTTP, ZKSYNC_WS, VERSION, HEURISTKEY, COMPUT3KEY, IOINTELLIGENCE_API_KEY
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version) VERSION="$2"; shift 2 ;;
    --zksync-http) ZKSYNC_HTTP="$2"; shift 2 ;;
    --zksync-ws) ZKSYNC_WS="$2"; shift 2 ;;
    --password-file) PASSWORD_FILE="$2"; PW_SUPPLIED=1; shift 2 ;;
    --backup-pass-file) BACKUP_PASSPHRASE_FILE="$2"; BPW_SUPPLIED=1; shift 2 ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

require_root() { [[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }; }
log()  { echo -e "\033[1;34m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\033[1;31m[x] $*\033[0m" >&2; exit 1; }

fetch_latest_version() {
  log "Detecting latest version from GCS…"
  local latest
  latest="$(curl -sfL "https://storage.googleapis.com/storage/v1/b/gh-af/o?prefix=genlayer-node/bin/amd64" \
    | grep -o '"name": *"[^"]*"' \
    | sed -n 's/.*\/\(v[^/]*\)\/.*/\1/p' | sort -ru | head -n1 || true)"
  [[ -n "$latest" ]] || die "Could not detect latest version."
  VERSION="$latest"
  log "Latest available: ${VERSION}"
}

install_prereqs() {
  log "Installing prerequisites…"
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl wget jq tar coreutils systemd
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker Engine…"
    apt-get install -y --no-install-recommends gpg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg" \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
$(. /etc/os-release; echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  fi
}

prepare_dirs() {
  log "Preparing directories…"
  install -d -m 0755 "$INSTALL_ROOT" "$DATA_DIR" "$BACKUP_DIR" "$ENV_DIR" "$SECRETS_DIR"
  chmod 0700 "$SECRETS_DIR"
}

ask_if_empty() {
  # Interactive prompts only when values are missing and not in non-interactive mode
  if [[ -z "${ZKSYNC_HTTP}" && $NONINTERACTIVE -eq 0 ]]; then
    read -rp "Enter your ZKSync HTTP RPC URL: " ZKSYNC_HTTP
  fi
  if [[ -z "${ZKSYNC_WS}" && $NONINTERACTIVE -eq 0 ]]; then
    read -rp "Enter your ZKSync WebSocket RPC URL: " ZKSYNC_WS
  fi
  if [[ -z "${VERSION}" && $NONINTERACTIVE -eq 0 ]]; then
    read -rp "Enter version (leave empty for latest): " VERSION || true
  fi
  # Passwords
  if [[ $PW_SUPPLIED -eq 0 ]]; then
    if [[ $NONINTERACTIVE -eq 1 ]]; then
      [[ -f "$PASSWORD_FILE" ]] || die "Missing --password-file in non-interactive mode."
    else
      while :; do
        read -rsp "Enter validator account password: " p1; echo
        read -rsp "Re-enter password: " p2; echo
        [[ "$p1" == "$p2" ]] && [[ -n "$p1" ]] && { echo -n "$p1" > "$PASSWORD_FILE"; chmod 600 "$PASSWORD_FILE"; break; }
        echo "Passwords do not match or empty. Try again."
      done
    fi
  fi
  if [[ $BPW_SUPPLIED -eq 0 ]]; then
    if [[ $NONINTERACTIVE -eq 1 ]]; then
      [[ -f "$BACKUP_PASSPHRASE_FILE" ]] || die "Missing --backup-pass-file in non-interactive mode."
    else
      while :; do
        read -rsp "Enter backup encryption passphrase: " b1; echo
        [[ -n "$b1" ]] && { echo -n "$b1" > "$BACKUP_PASSPHRASE_FILE"; chmod 600 "$BACKUP_PASSPHRASE_FILE"; break; }
        echo "Passphrase cannot be empty. Try again."
      done
    fi
  fi
  [[ -n "$ZKSYNC_HTTP" && -n "$ZKSYNC_WS" ]] || die "ZKSYNC_HTTP and ZKSYNC_WS are required."
}

download_release() {
  [[ -n "$VERSION" ]] || fetch_latest_version
  local url="https://storage.googleapis.com/gh-af/genlayer-node/bin/amd64/${VERSION}/genlayer-node-linux-amd64-${VERSION}.tar.gz"
  local tgz="/tmp/genlayer-${VERSION}.tar.gz"
  log "Downloading ${url}"
  curl -fL "$url" -o "$tgz"
  local rel_dir="${INSTALL_ROOT}/${VERSION}"
  rm -rf "$rel_dir"; mkdir -p "$rel_dir"
  tar -xzvf "$tgz" -C "$rel_dir"
  ln -snf "$rel_dir" "${INSTALL_ROOT}/current"
  log "Installed to ${rel_dir} and symlinked to ${INSTALL_ROOT}/current"
}

write_config() {
  install -d -m 0755 "${INSTALL_ROOT}/current/configs/node"
  cat > "${CONF_DIR}/config.yaml" <<EOF
rollup:
  zksyncurl: "${ZKSYNC_HTTP}"
  zksyncwebsocketurl: "${ZKSYNC_WS}"
consensus:
  contractmainaddress: "${CONSENSUS_MAIN}"
  contractdataaddress: "${CONSENSUS_DATA}"
  genesis: ${GENESIS_BLOCK}
datadir: "${DATA_DIR}/node"
logging:
  level: "INFO"
  json: false
  file:
    enabled: true
    level: "DEBUG"
    folder: logs
    maxsize: 10
    maxage: 7
    maxbackups: 100
    localtime: false
    compress: true
node:
  mode: "validator"
  admin: { port: 9155 }
  rpc:
    port: 9151
    endpoints:
      groups:
        genlayer: true
        genlayer_debug: true
        ethereum: true
        zksync: true
      methods:
        gen_call: true
        gen_getContractSchema: true
        gen_getTransactionStatus: true
        gen_getTransactionReceipt: true
        gen_dbg_ping: true
        gen_dbg_load_test: true
        eth_blockNumber: true
        eth_getBlockByNumber: true
        eth_getBlockByHash: true
        eth_getBalance: true
        eth_getTransactionCount: true
        eth_getTransactionReceipt: true
        eth_getLogs: true
        eth_getCode: true
        eth_sendRawTransaction: false
        debug_icStateDump: false
  ops:
    port: 9153
    endpoints: { metrics: true, health: true, balance: true }
genvm:
  bin_dir: ./third_party/genvm/bin
  manage_modules: true
merkleforest:
  maxdepth: 16
  dbpath: "${DATA_DIR}/node/merkle/forest/data.db"
  indexdbpath: "${DATA_DIR}/node/merkle/index.db"
merkletree:
  maxdepth: 16
  dbpath: "${DATA_DIR}/node/merkle/tree/"
metrics:
  interval: "15s"
EOF
  log "Wrote ${CONF_DIR}/config.yaml"
}

write_env() {
  umask 077
  cat > "$ENV_FILE" <<EOF
GENLAYER_PASSWORD=$(printf %q "$(cat "$PASSWORD_FILE")")
BACKUP_PASSPHRASE=$(printf %q "$(cat "$BACKUP_PASSPHRASE_FILE")")
HEURISTKEY=${HEURISTKEY}
COMPUT3KEY=${COMPUT3KEY}
IOINTELLIGENCE_API_KEY=${IOINTELLIGENCE_API_KEY}
EOF
  chmod 0600 "$ENV_FILE"
  log "Wrote ${ENV_FILE}"
}

precompile_genvm() {
  if [[ -x "${INSTALL_ROOT}/current/third_party/genvm/bin/genvm" ]]; then
    log "Precompiling GenVM wasm modules…"
    (cd "${INSTALL_ROOT}/current" && ./third_party/genvm/bin/genvm precompile || true)
  else
    warn "GenVM binary not found; skipping precompile."
  fi
}

maybe_compose_up_webdriver() {
  if [[ -f "${INSTALL_ROOT}/current/docker-compose.yml" || -f "${INSTALL_ROOT}/current/compose.yml" || -f "${INSTALL_ROOT}/current/docker-compose.yaml" ]]; then
    log "Starting WebDriver via docker compose…"
    (cd "${INSTALL_ROOT}/current" && docker compose up -d)
  else
    warn "No compose file found; skipping WebDriver autostart."
  fi
}

create_account_and_backup() {
  if [[ -f "$ADDR_FILE" ]]; then
    warn "Address exists at ${ADDR_FILE}; skipping account creation."
    return 0
  fi
  log "Creating validator account…"
  set +e
  out="$(
    cd "${INSTALL_ROOT}/current" && \
    ./bin/genlayernode account new -c "$(pwd)/configs/node/config.yaml" \
      --setup --password "$(cat "$PASSWORD_FILE")" 2>&1
  )"; rc=$?
  set -e
  echo "$out"
  [[ $rc -eq 0 ]] || die "Account creation failed."
  addr="$(echo "$out" | awk '/New address:/ {print $3}' | tail -n1)"
  [[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "Could not parse validator address."
  echo -n "$addr" > "$ADDR_FILE"; chmod 0600 "$ADDR_FILE"
  log "Validator address: $addr"

  local ts backup_path
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_path="${BACKUP_DIR}/validator-${ts}.key"
  log "Exporting encrypted key backup to ${backup_path}"
  (
    cd "${INSTALL_ROOT}/current" && \
    ./bin/genlayernode account export \
      --password "$(cat "$PASSWORD_FILE")" \
      --address "$addr" \
      --passphrase "$(cat "$BACKUP_PASSPHRASE_FILE")" \
      --path "$backup_path" \
      -c "$(pwd)/configs/node/config.yaml"
  )
  chmod 600 "$backup_path"
  log "Backup created."
}

install_systemd() {
  log "Installing systemd units…"
  cat > "/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=GenLayer Node
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_ROOT}/current
EnvironmentFile=${ENV_FILE}
ExecStart=/bin/bash -lc './bin/genlayernode run -c \$(pwd)/configs/node/config.yaml --password "\${GENLAYER_PASSWORD}"'
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_CHOWN CAP_DAC_OVERRIDE CAP_SETUID CAP_SETGID
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF

  cat > "/etc/systemd/system/genlayer-backup.service" <<EOF
[Unit]
Description=GenLayer Encrypted Key Backup

[Service]
Type=oneshot
User=root
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${INSTALL_ROOT}/current
ExecStart=/bin/bash -lc '
  set -euo pipefail
  ADDR=\$(cat ${ADDR_FILE})
  [[ -n "\$ADDR" ]]
  TS=\$(date -u +%Y%m%dT%H%M%SZ)
  DEST=${BACKUP_DIR}/validator-\${TS}.key
  ./bin/genlayernode account export \
    --password "\${GENLAYER_PASSWORD}" \
    --address "\$ADDR" \
    --passphrase "\${BACKUP_PASSPHRASE}" \
    --path "\$DEST" \
    -c \$(pwd)/configs/node/config.yaml
  chmod 600 "\$DEST"
'
EOF

  cat > "/etc/systemd/system/genlayer-backup.timer" <<'EOF'
[Unit]
Description=Run GenLayer key backup daily
[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=300
[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now genlayer-backup.timer
  systemctl enable --now "${SERVICE_NAME}"
  log "systemd service + timer enabled."
}

doctor_check() {
  log "Running doctor…"
  (cd "${INSTALL_ROOT}/current" && ./bin/genlayernode doctor || true)
}

print_summary() {
  echo
  echo "========================================"
  echo " GenLayer node installed & started"
  echo "----------------------------------------"
  echo "Version:           ${VERSION}"
  echo "Config:            ${CONF_DIR}/config.yaml"
  echo "Data dir:          ${DATA_DIR}"
  echo "Env file:          ${ENV_FILE} (0600)"
  [[ -f "${ADDR_FILE}" ]] && echo "Validator address: $(cat "${ADDR_FILE}")"
  echo "Metrics:           http://<host>:9153/metrics"
  echo "RPC:               http://<host>:9151/"
  echo "Backups dir:       ${BACKUP_DIR}"
  echo "Daily backups:     genlayer-backup.timer"
  echo "Service:           systemctl status ${SERVICE_NAME}"
  echo "Logs:              journalctl -u ${SERVICE_NAME} -f"
  echo "========================================"
}

main() {
  require_root
  install_prereqs
  prepare_dirs
  ask_if_empty
  [[ -n "$VERSION" ]] || fetch_latest_version
  download_release
  write_config
  write_env
  precompile_genvm
  maybe_compose_up_webdriver
  create_account_and_backup
  install_systemd
  doctor_check
  print_summary
}

main "$@"
