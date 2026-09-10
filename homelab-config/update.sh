#!/bin/bash
cd ~/homelab
echo "Pulling latest images..."
docker compose pull
echo "Restarting with new images..."
docker compose up -d
echo "Cleaning old images..."
docker image prune -f
echo "Done!"
