#!/bin/bash

# Force location
cd "$(dirname "$0")" || exit

# Source env
source .env

/root/.acme.sh/acme.sh --cron --home "/root/.acme.sh"
cp /root/.acme.sh/*.kr7.hu/fullchain.cer /etc/caddy/kr7.hu.crt
cp /root/.acme.sh/*.kr7.hu/*.kr7.hu.key /etc/caddy/kr7.hu.key
systemctl restart caddy.service

# To prevent HTTP AUTH coming back at night, we force the caching mechanism of `nopasswd` to set the machines
echo > /etc/caddy/nopasswd-hosts
