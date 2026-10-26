#!/bin/bash
# Removes the xmrig control API. Run as root. Does NOT touch xmrig.service.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Please run as root (sudo ./uninstall.sh)." >&2; exit 1; }

# ask VAR "Question" "default"  (uses the default when not run interactively)
ask() {
    local __var=$1 __prompt=$2 __def=$3 __ans=""
    if [ -t 0 ]; then
        read -r -p "$__prompt [$__def]: " __ans
    fi
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

API_UNIT=xmrig-api.service
UNIT_FILE=/etc/systemd/system/$API_UNIT

# Read settings from the existing install (before deleting anything)
ENV_FILE=""
[ -f "$UNIT_FILE" ] && ENV_FILE=$(sed -n 's/^EnvironmentFile=//p' "$UNIT_FILE" | head -n1)
CONFIG=""
if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    CONFIG=$(sed -n 's/^XMRIG_CONFIG=//p' "$ENV_FILE" | head -n1)
fi

echo "This will remove: the $API_UNIT service, its polkit rule and /opt/xmrig-api."
ask GO "Continue? (yes/no)" "no"
[ "$GO" = "yes" ] || { echo "Aborted."; exit 0; }

if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    ask DEL_ENV "Also delete the env file $ENV_FILE (contains the token)? (yes/no)" "yes"
else
    DEL_ENV=no
fi
if [ -d /var/lib/xmrig-api ]; then
    ask DEL_STATE "Also delete /var/lib/xmrig-api (config.json backup)? (yes/no)" "yes"
else
    DEL_STATE=no
fi
if id xmrig-api &>/dev/null; then
    ask DEL_USER "Also delete the 'xmrig-api' user and group? (yes/no)" "yes"
else
    DEL_USER=no
fi

# ---------- Remove the API service ----------
systemctl stop "$API_UNIT" 2>/dev/null || true
systemctl disable "$API_UNIT" 2>/dev/null || true
systemctl kill "$API_UNIT" 2>/dev/null || true
rm -f "$UNIT_FILE"
rm -rf "/etc/systemd/system/$API_UNIT.d"
# leftover enablement symlinks (e.g. multi-user.target.wants/)
find /etc/systemd/system -maxdepth 2 -name "$API_UNIT" -delete 2>/dev/null || true
systemctl daemon-reload
systemctl reset-failed "$API_UNIT" 2>/dev/null || true

rm -f /etc/polkit-1/rules.d/50-xmrig-api.rules
rm -rf /opt/xmrig-api

# remove the ACL we added on xmrig's config.json (the file itself is not touched otherwise)
if [ -n "$CONFIG" ] && [ -f "$CONFIG" ] && command -v setfacl >/dev/null; then
    setfacl -x u:xmrig-api "$CONFIG" 2>/dev/null || true
fi

if [ "$DEL_STATE" = "yes" ]; then
    rm -rf /var/lib/xmrig-api
fi

if [ "$DEL_ENV" = "yes" ]; then
    rm -f "$ENV_FILE"
    # remove the directory only if it is empty (never force-delete a shared directory)
    rmdir --ignore-fail-on-non-empty "$(dirname "$ENV_FILE")" 2>/dev/null || true
fi

if [ "$DEL_USER" = "yes" ]; then
    userdel xmrig-api 2>/dev/null || true
    if getent group xmrig-api >/dev/null; then groupdel xmrig-api 2>/dev/null || true; fi
fi

echo "Done. xmrig.service was not modified."
[ "$DEL_ENV" = "yes" ] || [ -z "$ENV_FILE" ] || echo "Env file kept: $ENV_FILE"
