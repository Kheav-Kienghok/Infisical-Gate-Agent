#!/usr/bin/env bash
# Run on the client (Odoo host) as root:
#   sudo SERVER=54.89.17.112 CLIENT_ID=xxx CLIENT_SECRET=yyy ./install.sh
# Put the server's fullchain.pem next to this script as ca.crt first.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER="${SERVER:?set SERVER=<ip or domain>}"
BIN="$(command -v infisical)" || { echo "infisical CLI not installed"; exit 1; }
[ -f "$HERE/ca.crt" ] || { echo "missing $HERE/ca.crt (copy server certs/fullchain.pem)"; exit 1; }

if [ -z "${CLIENT_ID:-}" ];     then read -rp  "Client ID: " CLIENT_ID; fi
if [ -z "${CLIENT_SECRET:-}" ]; then read -rsp "Client secret: " CLIENT_SECRET; echo; fi

# trust the self-signed cert system-wide
install -m 644 "$HERE/ca.crt" /usr/local/share/ca-certificates/infisical.crt
update-ca-certificates

# service user + config dir
id infisical >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin infisical
install -d -m 750 -o root -g infisical /etc/infisical
printf '%s' "$CLIENT_ID"     > /etc/infisical/client-id
printf '%s' "$CLIENT_SECRET" > /etc/infisical/client-secret
chown root:infisical /etc/infisical/client-id /etc/infisical/client-secret
chmod 640 /etc/infisical/client-id /etc/infisical/client-secret

sed "s|__SERVER__|${SERVER}|" "$HERE/agent.yaml" > /etc/infisical/agent.yaml
install -m 640 -o root -g infisical "$HERE/templates/odoo.env.tmpl" /etc/infisical/odoo.env.tmpl
chown root:infisical /etc/infisical/agent.yaml; chmod 640 /etc/infisical/agent.yaml

sed "s|__BIN__|${BIN}|" "$HERE/infisical-agent.service" > /etc/systemd/system/infisical-agent.service
systemctl daemon-reload
systemctl enable --now infisical-agent
sleep 3
systemctl --no-pager status infisical-agent || true
echo
echo "Token:        /run/infisical/token"
echo "Rendered env: /run/infisical/odoo.env"
echo "Let another service read them: sudo usermod -aG infisical <user>"
