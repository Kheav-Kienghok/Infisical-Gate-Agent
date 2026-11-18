# Infisical + Traefik (self-signed TLS, IP based) + Infisical Agent
# Override on the command line, e.g.:  make up PUBLIC_IP=1.2.3.4 PRIVATE_IP=10.0.0.5

PUBLIC_IP  ?= 54.89.17.112
PRIVATE_IP ?= 172.31.46.115
SERVER_DIR := server
CLIENT_DIR := client
COMPOSE    := cd $(SERVER_DIR) && podman-compose -f docker-compose.prod.yml
PROJECT_ID ?= 096fc433-cf41-4939-a2be-86b62679c5bb
SECRET_ENV ?= dev

.DEFAULT_GOAL := help
.PHONY: help check env siteurl cert cert-renew up down restart ps logs logs-traefik status reset \
	    client-ca client-install client-test client-status client-logs client-restart client-token client-secrets client-uninstall

help: ## Show this help
	@echo "Server targets (run on the Infisical host):"
	@grep -E '^[a-zA-Z_-]+:.*?## \[server\]' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## \\[server\\] "}{printf "  %-18s %s\n",$$1,$$2}'
	@echo ""
	@echo "Client targets (run on the Odoo/app host):"
	@grep -E '^[a-zA-Z_-]+:.*?## \[client\]' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## \\[client\\] "}{printf "  %-18s %s\n",$$1,$$2}'
	@echo ""
	@echo "Current: PUBLIC_IP=$(PUBLIC_IP) PRIVATE_IP=$(PRIVATE_IP)"

check: ## [server] Check required tools are installed
	@for t in podman podman-compose openssl curl; do command -v $$t >/dev/null && echo "ok   $$t" || echo "MISSING $$t"; done

# ------------------------------------------------------------------ server
env: ## [server] Create server/.env with random secrets (never overwrites)
	@if [ -f $(SERVER_DIR)/.env ]; then echo "$(SERVER_DIR)/.env already exists, not touching it"; else \
	    PG=$$(openssl rand -hex 24); \
	    { echo "POSTGRES_USER=infisical"; \
	      echo "POSTGRES_PASSWORD=$$PG"; \
	      echo "POSTGRES_DB=infisical"; \
	      echo "DB_CONNECTION_URI=postgresql://infisical:$$PG@db:5432/infisical"; \
	      echo "REDIS_URL=redis://redis:6379"; \
	      echo "ENCRYPTION_KEY=$$(openssl rand -hex 16)"; \
	      echo "AUTH_SECRET=$$(openssl rand -base64 32)"; \
	      echo "SITE_URL=https://$(PUBLIC_IP)"; \
	      echo "TELEMETRY_ENABLED=false"; } > $(SERVER_DIR)/.env; \
	    chmod 600 $(SERVER_DIR)/.env; \
	    echo "Created $(SERVER_DIR)/.env (back up ENCRYPTION_KEY and AUTH_SECRET!)"; \
	fi

siteurl: ## [server] Set SITE_URL in server/.env to https://PUBLIC_IP
	@sed -i 's|^SITE_URL=.*|SITE_URL=https://$(PUBLIC_IP)|' $(SERVER_DIR)/.env
	@grep '^SITE_URL' $(SERVER_DIR)/.env

cert: ## [server] Generate the self-signed IP certificate (skips if it exists)
	@if [ -f $(SERVER_DIR)/certs/fullchain.pem ]; then echo "certs exist (use 'make cert-renew' to replace)"; \
	else cd $(SERVER_DIR) && ./scripts/generate-cert.sh $(PUBLIC_IP) $(PRIVATE_IP); fi

cert-renew: ## [server] Regenerate the certificate and restart Traefik
	cd $(SERVER_DIR) && ./scripts/generate-cert.sh $(PUBLIC_IP) $(PRIVATE_IP)
	-podman restart infisical-traefik
	@echo "Now run 'make client-ca' on every client."

up: env cert ## [server] Start Infisical + Traefik
	$(COMPOSE) up -d
	@echo "Wait ~1-2 min for first boot, then: make status"

down: ## [server] Stop everything (keeps data)
	$(COMPOSE) down

restart: ## [server] Recreate containers (re-reads .env)
	$(COMPOSE) up -d --force-recreate

ps: ## [server] Show containers
	$(COMPOSE) ps

logs: ## [server] Follow Infisical backend logs
	podman logs -f infisical-backend

logs-traefik: ## [server] Follow Traefik logs
	podman logs -f infisical-traefik

status: ## [server] Check HTTPS status endpoint locally
	@curl -sk -o /dev/null -w "https://localhost/api/status -> HTTP %{http_code}\n" https://localhost/api/status || echo "not reachable yet"
	@curl -sk -o /dev/null -w "http://localhost  (redirect)  -> HTTP %{http_code}\n" http://localhost/ || true

reset: ## [server] DANGER: stop and DELETE database/redis volumes
	@read -p "This deletes all Infisical data. Type 'yes': " a; \
	if [ "$$a" = "yes" ]; then $(COMPOSE) down -v; else echo "aborted"; fi

# ------------------------------------------------------------------ client
client-ca: ## [client] Download the server certificate to client/ca.crt
	@echo | openssl s_client -connect $(PUBLIC_IP):443 2>/dev/null | openssl x509 > $(CLIENT_DIR)/ca.crt
	@openssl x509 -in $(CLIENT_DIR)/ca.crt -noout -subject -fingerprint -sha256 -enddate
	@echo "Compare this fingerprint with the server: openssl x509 -in server/certs/fullchain.pem -noout -fingerprint -sha256"

client-install: ## [client] Install CA + agent + systemd service (prompts for ID/secret if unset)
	@test -f $(CLIENT_DIR)/ca.crt || { echo "run 'make client-ca' first"; exit 1; }
	cd $(CLIENT_DIR) && sudo SERVER=$(PUBLIC_IP) CLIENT_ID="$(CLIENT_ID)" CLIENT_SECRET="$(CLIENT_SECRET)" ./install.sh

client-test: ## [client] Test HTTPS to the server using client/ca.crt
	curl -i --cacert $(CLIENT_DIR)/ca.crt https://$(PUBLIC_IP)/api/status

client-status: ## [client] systemd status of the agent
	systemctl --no-pager status infisical-agent

client-logs: ## [client] Follow agent logs
	journalctl -u infisical-agent -f

client-restart: ## [client] Restart the agent
	sudo systemctl restart infisical-agent

client-token: ## [client] Show token file info (not the token itself)
	@sudo ls -l /run/infisical/ && sudo sh -c 'echo "token length: $$(wc -c < /run/infisical/token)"'

client-secrets: ## [client] List secrets using the agent token
	INFISICAL_TOKEN=$$(sudo cat /run/infisical/token) infisical secrets --projectId=$(PROJECT_ID) --env=$(SECRET_ENV) --domain=https://$(PUBLIC_IP)

client-uninstall: ## [client] Remove agent, service, credentials and trusted cert
	-sudo systemctl disable --now infisical-agent
	-sudo rm -f /etc/systemd/system/infisical-agent.service
	-sudo rm -rf /etc/infisical
	-sudo rm -f /usr/local/share/ca-certificates/infisical.crt
	-sudo update-ca-certificates --fresh
	-sudo userdel infisical
	sudo systemctl daemon-reload
