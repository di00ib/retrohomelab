#!/bin/bash
cd ~/homelab
if [ -z "$1" ]; then
  echo "Usage: ./logs.sh [container-name]"
  echo "Containers: nginx nextcloud plex"
  echo "            vaultwarden homeassistant frigate"
  echo "            code-server jupyter portainer samba"
  echo "            retro-server megatools collabora"
else
  docker compose logs -f "$1"
fi
