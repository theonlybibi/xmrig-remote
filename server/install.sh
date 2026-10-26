#!/bin/bash
# Installs the xmrig control API. Run as root from the server/ directory.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Please run as root (sudo ./install.sh)." >&2; exit 1; }
cd "$(dirname "$0")"

# ask VAR "Question" "default"  (uses the default when not run interactively)
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
    chown root:root "$tmp"; chmod 600 "$tmp"
    mv "$tmp" "$ENV_FILE"
}

# ---------- Questions ----------
ask ENV_FILE "Where should the .env file be stored? (use a root-owned location)" "/etc/xmrig-api/xmrig-api.env"
[[ "$ENV_FILE" =~ ^/[A-Za-z0-9._/-]+$ && "$ENV_FILE" != */ ]] || die "invalid path (absolute path, letters/digits/._- only)"
if [[ "$ENV_FILE" == /home/* ]]; then
    echo "Warning: files under /home can be replaced by the owner of that directory."
    ask CONFIRM "Use this location anyway? (yes/no)" "no"
    [ "$CONFIRM" = "yes" ] || die "aborted; choose a location such as /etc/xmrig-api/"
fi

NEW_ENV=0
OLD_CONFIG=""
if [ -f "$ENV_FILE" ]; then
    echo "Existing env file found, keeping its settings: $ENV_FILE"
    UNIT=$(sed -n 's/^XMRIG_UNIT=//p' "$ENV_FILE" | head -n1)
    UNIT=${UNIT:-xmrig.service}
    OLD_CONFIG=$(sed -n 's/^XMRIG_CONFIG=//p' "$ENV_FILE" | head -n1)
else
    NEW_ENV=1
    ask UNIT   "systemd unit to control" "xmrig.service"
    ask HOST   "Listen address (127.0.0.1 = local only; use your VPN IP for remote access)" "127.0.0.1"
    ask PORT   "Listen port" "8080"
fi
[[ "$UNIT" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || die "invalid unit name"

# xmrig config.json (for thread control): detect it from the unit, let the user confirm/change
CFG_DEFAULT=$OLD_CONFIG
[ -n "$CFG_DEFAULT" ] || CFG_DEFAULT=$(XMRIG_UNIT="$UNIT" python3 xmrig_api.py --find-config 2>/dev/null || true)
ask CONFIG "Path to the xmrig config.json (type 'none' to disable thread control)" "$CFG_DEFAULT"
[ "$CONFIG" != "none" ] || CONFIG=""
ask EXTRA_GROUP "Extra group for the xmrig-api user (leave empty for none)" ""

# ---------- Validation ----------
if [ "$NEW_ENV" = 1 ]; then
    [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "port must be 1024-65535"
    [[ "$HOST" =~ ^[0-9A-Fa-f:.]+$ ]] || die "invalid listen address (use an IP address)"
fi
if [ -n "$EXTRA_GROUP" ]; then
    getent group "$EXTRA_GROUP" >/dev/null || die "group '$EXTRA_GROUP' does not exist"
fi
if [ -n "$CONFIG" ]; then
    [[ "$CONFIG" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid config path (absolute path, letters/digits/._- only)"
    [ -f "$CONFIG" ] || die "config file not found: $CONFIG"
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CONFIG" 2>/dev/null || die "$CONFIG is not valid JSON"
fi

# ---------- Install ----------
if ! id xmrig-api &>/dev/null; then
    args=(--system --no-create-home --shell "$(command -v nologin || echo /usr/sbin/nologin)" -U)
    [ -n "$EXTRA_GROUP" ] && args+=(-G "$EXTRA_GROUP")
    useradd "${args[@]}" xmrig-api
elif [ -n "$EXTRA_GROUP" ]; then
    echo "User xmrig-api already exists; add the group yourself if needed: usermod -aG $EXTRA_GROUP xmrig-api"
fi

install -d -m 755 -o root -g root /opt/xmrig-api
install -m 755 -o root -g root xmrig_api.py /opt/xmrig-api/xmrig_api.py

ENV_DIR=$(dirname "$ENV_FILE")
[ -d "$ENV_DIR" ] || install -d -m 700 -o root -g root "$ENV_DIR"

if [ "$NEW_ENV" = 1 ]; then
    TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
    (
        umask 077
        cat > "$ENV_FILE" <<ENV
API_TOKEN=$TOKEN
API_HOST=$HOST
API_PORT=$PORT
XMRIG_UNIT=$UNIT
ENV
    )
    chown root:root "$ENV_FILE"
    chmod 600 "$ENV_FILE"
fi
set_env XMRIG_CONFIG "$CONFIG"

# Give xmrig-api write access to config.json ONLY (ACL on that single file, no group, no directory access)
if [ -n "$CONFIG" ]; then
    if [ -n "$OLD_CONFIG" ] && [ "$OLD_CONFIG" != "$CONFIG" ] && command -v setfacl >/dev/null; then
        setfacl -x u:xmrig-api "$OLD_CONFIG" 2>/dev/null || true
    fi
    if command -v setfacl >/dev/null && setfacl -m u:xmrig-api:rw "$CONFIG" 2>/dev/null; then
        :
    else
        echo "Warning: could not set an ACL (install the 'acl' package, or the filesystem lacks ACL support)."
        echo "         Grant access manually, e.g.: chmod g+w '$CONFIG' && usermod -aG <file-group> xmrig-api"
    fi
    if runuser -u xmrig-api -- test -r "$CONFIG" && runuser -u xmrig-api -- test -w "$CONFIG"; then
        echo "OK: xmrig-api can read and write $CONFIG"
    else
        echo "WARNING: xmrig-api cannot read/write $CONFIG yet; thread control will fail until it can."
    fi
fi

PROTECT_HOME=yes
[[ "$CONFIG" == /home/* ]] && PROTECT_HOME=read-only
sed -e "s|@UNIT@|$UNIT|g" 50-xmrig-api.rules > /etc/polkit-1/rules.d/50-xmrig-api.rules
chmod 644 /etc/polkit-1/rules.d/50-xmrig-api.rules
sed -e "s|@ENV_FILE@|$ENV_FILE|g" -e "s|@PROTECT_HOME@|$PROTECT_HOME|g" \
    -e "s|@CONFIG_DIR@|$(dirname "${CONFIG:-/nonexistent}")|g" xmrig-api.service > /etc/systemd/system/xmrig-api.service
[ -n "$CONFIG" ] || sed -i '/^ReadWritePaths=/d' /etc/systemd/system/xmrig-api.service
chmod 644 /etc/systemd/system/xmrig-api.service

systemctl daemon-reload
systemctl enable --now xmrig-api
systemctl restart xmrig-api

# ---------- Summary ----------
echo
echo "Installed. Env file: $ENV_FILE"
if [ "$NEW_ENV" = 1 ]; then
    echo "Your API token (shown only once, also stored in the env file): $TOKEN"
    case "$HOST" in
        127.0.0.1|::1) echo "The API only listens locally. Edit API_HOST in $ENV_FILE and restart xmrig-api to allow remote access." ;;
        *) echo "WARNING: the API speaks plain HTTP, so the token travels unencrypted."
           echo "         Only expose it on a VPN (WireGuard/Tailscale), or put a TLS reverse proxy in front,"
           echo "         and restrict the port with your firewall." ;;
    esac
fi
[ -z "$CONFIG" ] || echo "Thread control enabled for: $CONFIG (a backup of the previous version is kept in /var/lib/xmrig-api/)"
echo "Check hardening with: systemd-analyze security xmrig-api"
