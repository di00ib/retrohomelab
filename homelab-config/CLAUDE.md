Before doing anything else, read /mnt/multitronic-docs/SESSION-HANDOFF.md — it's the current source of truth for what's running, what's broken, and what's pending across the homelab (FIREBAT + MULTITRONIC). Always check it first for context before making changes.

That file lives on MULTITRONIC and is reached via an SMB mount (see /etc/fstab, mounted at /mnt/multitronic-docs with x-systemd.automount). If MULTITRONIC is off or unreachable, the mount will time out — fall back to the local SESSION-HANDOFF.md in this folder, which is a leaner technical copy, and flag the outage to Don.
