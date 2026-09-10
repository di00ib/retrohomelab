#!/bin/bash
cd ~/homelab
echo "=== CONTAINERS ==="
docker compose ps
echo ""
echo "=== DISK USAGE ==="
df -h /mnt/pool
echo ""
echo "=== MEMORY ==="
free -h
echo ""
echo "=== CPU TEMP ==="
cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | \
  awk '{printf "%.1f°C\n", $1/1000}'
