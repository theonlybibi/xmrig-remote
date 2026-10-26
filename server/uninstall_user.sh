#!/bin/bash
# Removes the xmrig control API (user service). Run as the same normal user. Does NOT touch xmrig.service.
set -euo pipefail

[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root (./uninstall_user.sh)." >&2; exit 1; }

ask() {
    local __var=$1 __prompt=$2 __def=$3 __ans=""
    if [ -t 0 ]; then
        read -r -p "$__prompt [$__def]: " __ans
    fi
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

API_UNIT=xmrig-api.service
CONF_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
UNIT_DIR=$CONF_HOME/systemd/user
UNIT_FILE=$UNIT_DIR/$API_UNIT
APP_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/xmrig-api
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/xmrig-api

# Read settings from the existing install (before deleting anything)
ENV_FILE=""
[ -f "$UNIT_FILE" ] && ENV_FILE=$(sed -n 's/^EnvironmentFile=//p' "$UNIT_FILE" | head -n1)
if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    S=$(sed -n 's/^XMRIG_API_STATE=//p' "$ENV_FILE" | head -n1)
    [ -z "$S" ] || STATE_DIR=$S
fi

echo "This will remove: the $API_UNIT user service and $APP_DIR."
ask GO "Continue? (yes/no)" "no"
[ "$GO" = "yes" ] || { echo "Aborted."; exit 0; }

DEL_ENV=no; DEL_STATE=no
if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    ask DEL_ENV "Also delete the env file $ENV_FILE (contains the token)? (yes/no)" "yes"
fi
if [ -d "$STATE_DIR" ]; then
    ask DEL_STATE "Also delete $STATE_DIR (config.json backup)? (yes/no)" "yes"
fi

systemctl --user stop "$API_UNIT" 2>/dev/null || true
systemctl --user disable "$API_UNIT" 2>/dev/null || true
rm -f "$UNIT_FILE"
rm -rf "$UNIT_DIR/$API_UNIT.d"
find "$UNIT_DIR" -maxdepth 2 -name "$API_UNIT" -delete 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user reset-failed "$API_UNIT" 2>/dev/null || true

rm -rf "$APP_DIR"
[ "$DEL_STATE" != "yes" ] || rm -rf "$STATE_DIR"
if [ "$DEL_ENV" = "yes" ]; then
    rm -f "$ENV_FILE"
    rmdir --ignore-fail-on-non-empty "$(dirname "$ENV_FILE")" 2>/dev/null || true
fi

echo "Done. xmrig.service was not modified."
[ "$DEL_ENV" = "yes" ] || [ -z "$ENV_FILE" ] || echo "Env file kept: $ENV_FILE"
