# XMRig Remote

HTTP API + KDE Plasma 6 widget to monitor / start / stop a systemd service (xmrig).

## Server (as root)

    cd server && sudo ./install.sh

The script asks for: the .env location, the systemd unit, the listen address/port
and an optional extra group. It prints the generated token once.

Uninstall (as root): `sudo ./uninstall.sh` (asks before deleting the env file and the user).

Test:

    curl -H "Authorization: Bearer TOKEN" http://IP:8080/status
    curl -X POST -H "Authorization: Bearer TOKEN" http://IP:8080/stop

Endpoints: `GET /status`, `POST /start`, `POST /stop`, `POST /restart`.

## Widget (Plasma 6, client machine)

    kpackagetool6 --type Plasma/Applet --install plasmoid     # use -u to upgrade
    systemctl --user restart plasma-plasmashell.service

Then right-click the desktop/panel > Add Widgets > "XMRig Control".
Test without adding it: `plasmawindowed com.github.theonlybibi.xmrigcontrol`

## Security notes

- Plain HTTP: the token is sent unencrypted. Use a VPN (WireGuard/Tailscale) or a TLS reverse proxy,
  and firewall the port.
- The widget stores the token in clear text in the Plasma config of the client user.
- The API user can only start/stop/restart the configured unit (polkit rule) and runs sandboxed.
