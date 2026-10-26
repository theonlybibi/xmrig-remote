#!/bin/bash
# Installs the xmrig control API as a systemd USER service.
# Run as your NORMAL user (not root), from the server/ directory.
# Starts at login (default.target), stops when your last session ends. No linger needed.
set -euo pipefail

[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root (./install_user.sh)." >&2; exit 1; }
cd "$(dirname "$0")"

ask() {
    local __var=$1 __prompt=$2 __def=$3 __ans=""
    if [ -t 0 ]; then
        read -r -p "$__prompt [${__def:-none}]: " __ans
    fi
    printf -v "$__var" '%s' "${__ans:-$__def}"
}
die() { echo "Error: $*" >&2; exit 1; }

# set_env KEY VALUE  (empty VALUE removes the key)
set_env() {
    local tmp
    tmp=$(mktemp "$ENV_FILE.XXXXXX")
    grep -v "^$1=" "$ENV_FILE" > "$tmp" || true
    [ -z "$2" ] || echo "$1=$2" >> "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$ENV_FILE"
}

PY=$(command -v python3) || die "python3 not found"
systemctl --user show-environment >/dev/null 2>&1 \
    || die "cannot reach your systemd user manager (use a normal login session; XDG_RUNTIME_DIR must be set)"

CONF_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
APP_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/xmrig-api
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/xmrig-api
UNIT_DIR=$CONF_HOME/systemd/user
PATH_RE='^/[A-Za-z0-9._/-]+$'
for p in "$CONF_HOME" "$APP_DIR" "$STATE_DIR" "$PY"; do
    [[ "$p" =~ $PATH_RE ]] || die "unsupported characters in path: $p"
done

# ---------- Questions ----------
ask ENV_FILE "Where should the .env file be stored?" "$CONF_HOME/xmrig-api/xmrig-api.env"
[[ "$ENV_FILE" =~ $PATH_RE && "$ENV_FILE" != */ ]] || die "invalid path (absolute path, letters/digits/._- only)"

NEW_ENV=0
OLD_CONFIG=""
if [ -f "$ENV_FILE" ]; then
    echo "Existing env file found, keeping its settings: $ENV_FILE"
    UNIT=$(sed -n 's/^XMRIG_UNIT=//p' "$ENV_FILE" | head -n1)
    UNIT=${UNIT:-xmrig.service}
    OLD_CONFIG=$(sed -n 's/^XMRIG_CONFIG=//p' "$ENV_FILE" | head -n1)
else
    NEW_ENV=1
    ask UNIT "systemd USER unit to control" "xmrig.service"
    ask HOST "Listen address (127.0.0.1 = local only; use your VPN IP for remote access)" "127.0.0.1"
    ask PORT "Listen port" "8080"
fi
[[ "$UNIT" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || die "invalid unit name"

systemctl --user cat "$UNIT" >/dev/null 2>&1 \
    || echo "Warning: '$UNIT' not found in your user manager (if it is a system unit, use install.sh instead)."

CFG_DEFAULT=$OLD_CONFIG
[ -n "$CFG_DEFAULT" ] || CFG_DEFAULT=$(XMRIG_SCOPE=user XMRIG_UNIT="$UNIT" "$PY" xmrig_api.py --find-config 2>/dev/null || true)
ask CONFIG "Path to the xmrig config.json (type 'none' to disable thread control)" "$CFG_DEFAULT"
[ "$CONFIG" != "none" ] || CONFIG=""

# ---------- Validation ----------
if [ "$NEW_ENV" = 1 ]; then
    [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "port must be 1024-65535"
    [[ "$HOST" =~ ^[0-9A-Fa-f:.]+$ ]] || die "invalid listen address (use an IP address)"
fi
if [ -n "$CONFIG" ]; then
    [[ "$CONFIG" =~ $PATH_RE ]] || die "invalid config path (absolute path, letters/digits/._- only)"
    [ -f "$CONFIG" ] || die "config file not found: $CONFIG"
    [ -r "$CONFIG" ] && [ -w "$CONFIG" ] || die "you cannot read/write $CONFIG"
    "$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$CONFIG" 2>/dev/null || die "$CONFIG is not valid JSON"
fi

# ---------- Install ----------
install -d -m 700 "$APP_DIR" "$STATE_DIR" "$(dirname "$ENV_FILE")" "$UNIT_DIR"
install -m 700 xmrig_api.py "$APP_DIR/xmrig_api.py"

if [ "$NEW_ENV" = 1 ]; then
    TOKEN=$("$PY" -c 'import secrets; print(secrets.token_hex(24))')
    (
        umask 077
        cat > "$ENV_FILE" <<ENV
API_TOKEN=$TOKEN
API_HOST=$HOST
API_PORT=$PORT
XMRIG_UNIT=$UNIT
ENV
    )
    chmod 600 "$ENV_FILE"
fi
set_env XMRIG_SCOPE user
set_env XMRIG_API_STATE "$STATE_DIR"
set_env XMRIG_CONFIG "$CONFIG"

sed -e "s|@ENV_FILE@|$ENV_FILE|g" -e "s|@PYTHON@|$PY|g" -e "s|@SCRIPT@|$APP_DIR/xmrig_api.py|g" \
    xmrig-api-user.service > "$UNIT_DIR/xmrig-api.service"
chmod 644 "$UNIT_DIR/xmrig-api.service"

systemctl --user daemon-reload
systemctl --user enable --now xmrig-api.service
systemctl --user restart xmrig-api.service
sleep 1
systemctl --user is-active --quiet xmrig-api.service \
    || echo "WARNING: xmrig-api is not running. See: journalctl --user -u xmrig-api -e"

# ---------- Summary ----------
echo
echo "Installed (user service). Env file: $ENV_FILE"
if [ "$NEW_ENV" = 1 ]; then
    echo "Your API token (shown only once, also stored in the env file): $TOKEN"
    case "$HOST" in
        127.0.0.1|::1) echo "The API only listens locally. Edit API_HOST in $ENV_FILE and run: systemctl --user restart xmrig-api" ;;
        *) echo "WARNING: the API speaks plain HTTP, so the token travels unencrypted."
           echo "         Only expose it on a VPN (WireGuard/Tailscale), or put a TLS reverse proxy in front,"
           echo "         and restrict the port with your firewall." ;;
    esac
fi
[ -z "$CONFIG" ] || echo "Thread control enabled for: $CONFIG (backup of the previous version in $STATE_DIR/)"
echo "It starts at your login and stops when your last session ends (no linger)."
