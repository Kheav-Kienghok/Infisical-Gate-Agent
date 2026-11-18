# Infisical + Traefik (HTTPS on an IP) + Infisical Agent

Self-hosted [Infisical](https://infisical.com) secrets manager running on **Podman**, with **Traefik**
terminating TLS using a **self-signed certificate that is valid for IP addresses**, and an
**Infisical Agent** on the client machine that logs in with a machine identity (Universal Auth),
keeps a short-lived token fresh, and renders secrets into a file for your app (e.g. Odoo).

No domain is needed. Everything is addressed by IP for now.

```
                 HTTPS 443 (self-signed)                    
 Client host  ───────────────────────────────►  Server host
 ┌──────────────────────┐                      ┌────────────────────────────────────┐
 │ infisical-agent      │                      │ Traefik :80 -> redirect to :443    │
 │  - universal auth    │                      │         :443 TLS                   │
 │  - /run/infisical/   │                      │            │ http (internal net)   │
 │      token           │                      │            ▼                       │
 │      odoo.env        │                      │ Infisical backend :8080            │
 └──────────────────────┘                      │    ├── Postgres 14                 │
                                               │    └── Redis 7                     │
                                               └────────────────────────────────────┘
```

Only Traefik publishes ports. The backend, Postgres and Redis are reachable only on the internal Podman network.

## Defaults used in this project

| Setting | Value |
|---|---|
| Server public IP | `54.89.17.112` |
| Server private IP | `172.31.46.115` |
| Infisical project ID | `096fc433-cf41-4939-a2be-86b62679c5bb` |
| Environment | `dev` |

Change them per command: `make up PUBLIC_IP=1.2.3.4 PRIVATE_IP=10.0.0.5`,
or edit the top of the `Makefile`. If you edit `client/templates/odoo.env.tmpl`, the project ID is in there too.

## Layout

```
Makefile                      all commands (run `make help`)
server/
  docker-compose.prod.yml     traefik + backend + postgres + redis
  .env.example                reference for server/.env (make env creates the real one)
  traefik/traefik.yml         entrypoints 80 (redirect) and 443, file provider
  traefik/dynamic/tls.yml     certificate paths, min TLS 1.2
  traefik/dynamic/infisical.yml   router + service -> http://backend:8080
  scripts/generate-cert.sh    self-signed cert with IP SANs
client/
  install.sh                  trusts the cert, creates service user, installs systemd unit
  agent.yaml                  agent config (universal auth, token sink, template)
  infisical-agent.service     systemd unit (runs as user "infisical")
  templates/odoo.env.tmpl     renders all secrets of the project/env into odoo.env
```

## Requirements

- **Server:** Ubuntu with `podman`, `podman-compose` (1.0.6+), `openssl`, `curl`, `make`.
  Rootless Podman needs low ports allowed:
  ```bash
  echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-podman.conf
  sudo sysctl --system
  ```
- **AWS security group (server):** inbound TCP 80 and 443.
- **Client:** the `infisical` CLI (agent included), `curl`, `openssl`, `make`, systemd.

## Quick start

### 1. Server

```bash
make check          # tools present?
make up             # creates .env + certificate if missing, starts the stack
make status         # expect HTTP 200 on the status endpoint (first boot takes 1-2 min)
```

Then open `https://54.89.17.112`, accept the browser warning (self-signed) and create the admin account.

Already have a `server/.env`? `make env` will not overwrite it. Just run `make siteurl` so
`SITE_URL=https://<PUBLIC_IP>`, then `make restart`.

Back up `ENCRYPTION_KEY` and `AUTH_SECRET` from `server/.env`. Without `ENCRYPTION_KEY` stored secrets cannot be decrypted.

### 2. Create a machine identity (UI)

1. **Organization -> Access Control -> Identities -> Create**, auth method **Universal Auth**.
2. Suggested: Access Token TTL `300`, Max TTL `3600`, trusted IP = the client host.
3. Add the identity to your project (**Project -> Access Control -> Machine Identities**) with a read-only role.
4. Create a **Client Secret** and copy the Client ID and Client Secret.

### 3. Client

Copy this folder to the client (or clone it), then:

```bash
make client-ca                      # fetches the server cert to client/ca.crt
make client-install                 # prompts for Client ID and Client Secret
make client-status
```

Non-interactive: `make client-install CLIENT_ID=... CLIENT_SECRET=...` (this puts the secret in your shell history; prefer the prompt).

`make client-ca` trusts whatever certificate the server presents on first contact. Verify it on the server:
```bash
openssl x509 -in server/certs/fullchain.pem -noout -fingerprint -sha256
```
and compare with the fingerprint printed on the client. Or copy `server/certs/fullchain.pem` to `client/ca.crt` with `scp` instead.

### 4. Use the secrets

The agent keeps two files fresh (refreshed every 60 s, stored in tmpfs, gone after reboot):

| File | Content |
|---|---|
| `/run/infisical/token` | short-lived access token |
| `/run/infisical/odoo.env` | `KEY=value` lines for every secret in the project/env (path `/`) |

Directory is `root`-unreadable-to-others: owner `infisical`, group `infisical`, mode `0750`.
Give an app's user access with `sudo usermod -aG infisical <user>` (log in again afterwards).

```bash
make client-secrets                                    # list via CLI
sudo cat /run/infisical/odoo.env                       # rendered file
set -a; . /run/infisical/odoo.env; set +a              # load into a shell
```

Odoo with systemd: add `EnvironmentFile=/run/infisical/odoo.env` and `After=infisical-agent.service` to the unit.
Odoo with Podman: `env_file: /run/infisical/odoo.env`.

## Makefile reference

Run `make help` for the live list.

| Target | Where | What it does |
|---|---|---|
| `check` | server | verifies podman, podman-compose, openssl, curl |
| `env` | server | creates `server/.env` with random secrets (never overwrites) |
| `siteurl` | server | sets `SITE_URL=https://PUBLIC_IP` in `.env` |
| `cert` / `cert-renew` | server | create / replace the self-signed cert (renew restarts Traefik) |
| `up` / `down` / `restart` | server | start, stop (data kept), recreate containers |
| `ps` / `logs` / `logs-traefik` / `status` | server | inspect |
| `reset` | server | deletes DB + Redis volumes after confirmation |
| `client-ca` | client | fetch server cert to `client/ca.crt` |
| `client-install` | client | trust cert, create user, install and start the agent service |
| `client-test` | client | `curl` the server using the pinned cert |
| `client-status` / `client-logs` / `client-restart` | client | manage the agent service |
| `client-token` | client | show token file info without printing the token |
| `client-secrets` | client | list secrets with the agent token |
| `client-uninstall` | client | remove everything the installer added |

Without `make`, the server commands are `cd server && podman-compose -f docker-compose.prod.yml up -d` etc.

## Security notes

- The certificate is self-signed, so every client has to trust it (`client-install` does this). It lasts 825 days; run `make cert-renew` and then `make client-ca` + `sudo update-ca-certificates` on clients before it expires.
- Pin the Infisical image tag in `server/docker-compose.prod.yml` (it says `latest`) so a restart doesn't upgrade you unexpectedly.
- `server/.env`, `server/certs/` and `client/ca.crt` are in `.gitignore`. Never commit them.
- Credentials live in `/etc/infisical/client-id` and `client-secret` (root:infisical, 0640). Give the Client Secret a TTL and a usage limit in the UI.
- Delete the old legacy service token once the agent works.
- Restrict ports 80/443 in the security group to the client IPs if you can.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `make status` shows 000 or 502 | backend still booting; `make logs` and wait for the cron lines, retry |
| `Invalid URL` in backend logs | `SITE_URL` in `server/.env` is a placeholder; `make siteurl` then `make restart` |
| `password authentication failed` | `.env` password differs from the DB volume; if it holds no data, `make reset` then `make up` |
| Cannot bind port 80/443 | set `net.ipv4.ip_unprivileged_port_start=80` (see Requirements) or run with sudo |
| Browser: `ERR_CERT_AUTHORITY_INVALID` | expected for self-signed; accept it or import `server/certs/fullchain.pem` |
| Client: `x509: certificate signed by unknown authority` | run `make client-install` (installs the CA) or `sudo update-ca-certificates` |
| Client: `x509: ... doesn't contain any IP SANs` / wrong IP | cert was made for other IPs; `make cert-renew PUBLIC_IP=... PRIVATE_IP=...` then `make client-ca` |
| Agent: `permission denied` writing token | restart the service; the unit creates `/run/infisical` via `RuntimeDirectory` |
| Agent: template error | check `make client-logs`; template syntax can vary by CLI version, see the Infisical Agent docs |
| Login works but UI redirects oddly | `SITE_URL` must equal the address you browse to (`https://54.89.17.112`) |

## Moving to a real domain later

1. Point a DNS name at the server, set `SITE_URL=https://your.domain`.
2. Replace the `tls.yml` certificate with Traefik's ACME/Let's Encrypt resolver (or your own cert).
3. Update `address:` in `client/agent.yaml` (and `SERVER` for the installer). Clients then no longer need the custom CA.
