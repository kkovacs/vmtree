#!/bin/bash

# Force location
cd "$(dirname "$0")" || exit

# Source env
source .env

# Run what acme.sh would put in cron
/root/.acme.sh/acme.sh --cron --home "/root/.acme.sh"

# Copy to place
install -o caddy -g caddy -m 644 /root/.acme.sh/"$DOMAIN"*/fullchain.cer /etc/caddy/vmtree.crt
install -o caddy -g caddy -m 600 /root/.acme.sh/"$DOMAIN"*/"$DOMAIN".key /etc/caddy/vmtree.key

# Restart Caddy
systemctl restart caddy.service

# To prevent HTTP AUTH coming back at night because of the restart,
# force the change detection mechanism of "cron-nopasswd.sh" to set things up fresh.
echo > /etc/caddy/nopasswd-hosts
