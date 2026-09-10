#!/bin/bash
echo "Checking .deleted folder sizes across all shares..."
docker exec samba sh -c 'du -sh /mnt/*/.deleted /mnt/*/*/.deleted 2>/dev/null'
echo ""
read -p "Empty all of these permanently? (y/n): " confirm
if [ "$confirm" = "y" ]; then
    sudo docker exec samba sh -c 'rm -rf /mnt/*/.deleted /mnt/*/*/.deleted 2>/dev/null'
    echo "Done - all .deleted folders cleared."
else
    echo "Cancelled - nothing was deleted."
fi
