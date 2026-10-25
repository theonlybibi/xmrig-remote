#!/bin/bash
# Removes the xmrig control API. Run as root. Does NOT touch xmrig.service itself.
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

UNIT_FILE=/etc/systemd/system/xmrig-api.service
ENV_FILE=""
[ -f "$UNIT_FILE" ] && ENV_FILE=$(sed -n 's/^EnvironmentFile=//p' "$UNIT_FILE" | head -n1)

echo "This will remove: the xmrig-api service, its polkit rule and /opt/xmrig-api."
ask GO         "Continue? (yes/no)" "no"
[ "$GO" = "yes" ] || { echo "Aborted."; exit 0; }
if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    ask DEL_ENV "Also delete the env file $ENV_FILE (contains the token)? (yes/no)" "yes"
else
    DEL_ENV=no
fi
if id xmrig-api &>/dev/null; then
    ask DEL_USER "Also delete the 'xmrig-api' user and group? (yes/no)" "yes"
else
    DEL_USER=no
fi

# ---------- Remove ----------
if systemctl list-unit-files xmrig-api.service &>/dev/null; then
    systemctl disable --now xmrig-api 2>/dev/null || true
fi
rm -f "$UNIT_FILE"
rm -f /etc/polkit-1/rules.d/50-xmrig-api.rules
rm -rf /opt/xmrig-api
systemctl daemon-reload
systemctl reset-failed xmrig-api 2>/dev/null || true

if [ "$DEL_ENV" = "yes" ]; then
    rm -f "$ENV_FILE"
    # remove the directory only if it is empty (never force-delete a shared directory)
    rmdir --ignore-fail-on-non-empty "$(dirname "$ENV_FILE")" 2>/dev/null || true
fi

if [ "$DEL_USER" = "yes" ]; then
    userdel xmrig-api 2>/dev/null || true
    getent group xmrig-api >/dev/null && groupdel xmrig-api 2>/dev/null || true
fi

echo "Done. xmrig.service was not modified."
[ "$DEL_ENV" = "yes" ] || [ -z "$ENV_FILE" ] || echo "Env file kept: $ENV_FILE"
