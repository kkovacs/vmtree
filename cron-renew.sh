#!/bin/bash

# Force location
cd "$(dirname "$0")" || exit

# Source env
source .env

/vmtree/.acme.sh/acme.sh --cron --home "/vmtree/.acme.sh"
cp /vmtree/.acme.sh/*.kr7.hu/fullchain.cer /etc/caddy/kr7.hu.crt
cp /vmtree/.acme.sh/*.kr7.hu/*.kr7.hu.key /etc/caddy/kr7.hu.key
systemctl restart caddy.service

# To prevent HTTP AUTH coming back at night because of the restart,
# force the change detection mechanism of "cron-nopasswd.sh" to set things up fresh.
echo > /etc/caddy/nopasswd-hosts
