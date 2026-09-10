# Session Handoff

**Note:** As of 2026-07-14, `CLAUDE.md` points Claude Code at
`/mnt/multitronic-docs/SESSION-HANDOFF.md` (mounted from MULTITRONIC) as the
primary handoff file. This local file is now a secondary/fallback technical
log, used if that mount is unreachable — see the mount setup entry below.

## 2026-07-14 — Mounted MULTITRONIC's retro-homelab share, made it the primary handoff file

**What:** Mounted the Windows SMB share `retro-homelab` from MULTITRONIC
(100.122.14.56) onto FIREBAT at `/mnt/multitronic-docs`, and repointed
`CLAUDE.md`'s startup instruction at the `SESSION-HANDOFF.md` on that share
instead of this local file.

**Install/mount:**
- Installed `cifs-utils` (`sudo apt-get install -y cifs-utils`).
- Created mount point `/mnt/multitronic-docs`.
- Credentials stored at `~/.smbcreds/multitronic` (`username=`/`password=`
  lines, mode `600`) — used via the `credentials=` mount option, not an
  inline password.
- `/etc/fstab` entry:
  ```
  //100.122.14.56/retro-homelab /mnt/multitronic-docs cifs credentials=/home/di0__0ib/.smbcreds/multitronic,uid=di0__0ib,gid=di0__0ib,iocharset=utf8,vers=3.0,_netdev,x-systemd.automount,x-systemd.mount-timeout=10 0 0
  ```
  `_netdev` + `x-systemd.automount` + a 10s mount timeout mean a
  temporarily-unreachable MULTITRONIC mounts lazily on first access and won't
  hang FIREBAT's boot.
- Verified with `mount -a`: share mounts read-write, files show correctly
  owned by `di0__0ib`, and `SESSION-HANDOFF.md` on the share is both readable
  and writable.

**Why point CLAUDE.md at the MULTITRONIC copy instead of this local file:**
That `SESSION-HANDOFF.md` (665 lines) is the full narrative handoff Don
maintains across both FIREBAT and MULTITRONIC work via a Cowork chat session,
and is far more current/complete than this local file. An earlier note in
that file described the two files as intentionally separate ("don't merge
them") — Don explicitly overrode that today in favor of Claude Code reading
the richer, canonical file directly. That file has been updated to reflect
this change.

**Known risk:** this makes Claude Code's startup context depend on MULTITRONIC
(a Windows desktop) being reachable over Tailscale. If it's asleep/off, the
mount will time out per the fstab options above — Claude Code should fall
back to reading this local file in that case.

## 2026-07-14 — Plex switched to network_mode: host

**Change:** `plex` service in `docker-compose.yml` moved from the `homelab` bridge
network to `network_mode: host` (needed for Plex, e.g. DLNA/GDM discovery). This
took it off the `homelab` network, so nginx could no longer resolve the container
name `plex` and `/plex` broke (502).

**Fix — connectivity:**
- Added `extra_hosts: ["host.docker.internal:host-gateway"]` to the `nginx`
  service in `docker-compose.yml`, giving nginx a stable route to the Docker host
  regardless of which bridge network it's on.
- `nginx/homelab.conf`: `/plex` now proxies to `http://host.docker.internal:32400`
  instead of `http://plex:32400`.

**Fix — subpath routing:**
Plex doesn't natively support being served from a subpath (its web app hardcodes
root-relative links). `nginx/homelab.conf` now handles this with a best-effort
rewrite rather than a dedicated subdomain:
- `location = /plex` redirects to `/plex/`.
- `location /plex/` proxies to `http://host.docker.internal:32400/` (prefix
  stripped on the way to Plex).
- `proxy_set_header Accept-Encoding ""` disables upstream gzip so `sub_filter`
  can actually rewrite response bodies.
- `sub_filter` rewrites root-relative `href="/"`, `src="/"`, and `"/web` to
  `/plex/...` in HTML/JS/JSON responses.
- `proxy_cookie_path / /plex/` keeps session cookies scoped correctly.

**Known limitation:** this is a best-effort text rewrite, not real subpath
support. A future Plex web update could introduce an absolute-path pattern the
`sub_filter` rules don't catch, breaking some assets or deep links — if that
happens, add a matching `sub_filter` rule. The alternative (more robust, more
work) is a dedicated subdomain server block for Plex with its own TLS cert,
which was considered and declined in favor of keeping the single `/plex` URL.

**Gotcha hit while fixing this:** editing `nginx/homelab.conf` on the host did
not propagate into the running container even after `nginx -s reload` — the
bind-mounted single file detached from the host inode after being rewritten.
Had to `docker compose up -d --force-recreate nginx` to pick up config changes.
Keep this in mind for any future nginx config edits.

**Status:** Fixed and verified — `/plex` redirects correctly, `/plex/identity`
returns 200 from Plex, and `/plex/web/index.html` asset links are rewritten
with the `/plex/` prefix.

## 2026-07-14 — New Samba share for docs

Added a dedicated read-write Samba share for documentation files, kept separate
from anything with credentials in it:

- Backing folder: `/home/di0__0ib/homelab-docs` on the host — deliberately
  **outside** `~/homelab`, so it stays away from `docker-compose.yml` and `.env`.
- Share name: `docs`, read-write, using the same `SAMBA_USER`/`SAMBA_PASS`
  credentials as the other shares (same `-s name;path;yes;no;no;${SAMBA_USER}`
  pattern in the `samba` service command, plus a matching volume mount).
- Applied via `docker compose up -d samba`; confirmed live with `smbclient -L`
  showing `docs` listed, and a write test through the container's mounted path
  confirmed it maps to the correct host folder.
- Windows mapping path: `\\100.73.67.43\docs` (same Tailscale IP used elsewhere,
  e.g. in `nginx/homelab.conf`).

**Follow-up — writes were blocked, fixed via permissions:**
The share was visible but read-only in practice — couldn't create folders or
copy files in, even with Windows admin approval. Root cause: `smb.conf` has a
global `force user = smbuser` / `force group = smb`, so *every* SMB connection
touches disk as unix account `smbuser` (uid 100), never as the folder's owner
`di0__0ib`. `homelab-docs` was mode `775` (owner+group write only), so
`smbuser` fell into the "other" class and got read+execute but no write.

Tested `smbuser` directly against every existing share to find the real
working pattern — turned out `nextcloud-data` and `recovered` aren't actually
writable through Samba either (same permission wall). The shares that genuinely
work (`plex`, `guitar-recordings`, `game-installers`, `j4.5-backup`) are all
mode `777`, because `smbuser` always lands in "other" regardless of which
share. That's the real (if inelegant) convention this setup relies on.

**Fix:** `chmod 777 /home/di0__0ib/homelab-docs`, matching the actual
writable-share pattern. Verified with a full real SMB session (authenticated
as the actual Samba user) — created a folder and uploaded a file, confirmed on
the host filesystem, then cleaned up.

**Note:** deletes through this share don't actually remove files — a global
recycle-bin config redirects them into a hidden `.deleted` folder (mode `700`,
owned by `smbuser`), which the host user can't read directly. This is existing
behavior across all shares, not something introduced by the docs share. Worth
keeping an eye on `.deleted` directories accumulating disk usage over time;
clean up requires root (`docker exec samba rm -rf <share>/.deleted`).

**If adding more Samba shares in the future:** any new share's backing folder
needs to be mode `777` (or otherwise grant write to uid 100 / gid 101) to
actually be writable, given the global `force user`/`force group` — matching
ownership to `di0__0ib` alone is not sufficient.

## 2026-07-14 — Full Samba share permission audit (later same night)

Followed up on the `docs`/`nextcloud-data`/`recovered` discovery above by
auditing the backing folder of **every** share defined in the `samba`
service command in `docker-compose.yml` (18 total, all configured
read-write: `yes;no;no;${SAMBA_USER}`). Also confirmed the host's own
`smbd`/`nmbd` are inactive/disabled — `/etc/samba/smb.conf` on the host
(with its stray `[24tb]` share pointing at a nonexistent `/mnt/24tb`) is
dead config, not actually serving anything. Only the `samba` container
(`dperson/samba`) is live.

**Before/after mode for every share's backing folder:**

| Share | Path | Before | After |
|---|---|---|---|
| shared | /mnt/pool/shared | 755 | **777** |
| plex | /mnt/pool/plex | 777 | 777 (already OK) |
| media | /mnt/pool/media | 755 root:root | **777** |
| exos26 | /mnt/exos26tb | 777 | 777 (already OK) |
| movies | /mnt/plex-movies | 777 | 777 (already OK) |
| tv | /mnt/plex-tv | 777 | 777 (already OK) |
| nvme1tb | /mnt/nvme1tb | 755 root:root | **777** |
| 24tb-recovered | /mnt/pool/24tb-recovered | 755 | **777** |
| frigate-recordings | /mnt/pool/frigate-recordings | 755 | **777** |
| game-installers | /mnt/pool/game-installers | 777 | 777 (already OK) |
| guitar-recordings | /mnt/pool/guitar-recordings | 777 | 777 (already OK) |
| homeassistant | /mnt/pool/homeassistant | 755 | **777** |
| immich-photos | /mnt/pool/immich-photos | 755 | **777** |
| j4.5-backup | /mnt/pool/j4.5-backup | 777 | 777 (already OK) |
| nextcloud-data | /mnt/pool/nextcloud-data | 770 www-data:www-data | **left at 770 — deliberate, see below** |
| recovered | /mnt/pool/recovered | 755 | **777** |
| retro-apps | /mnt/pool/retro-apps | 755 root:root | **777** |
| docs | /home/di0__0ib/homelab-docs | 777 | 777 (fixed earlier tonight, see above) |

10 folders fixed with `chmod 777` (4 of them — `media`, `nvme1tb`,
`retro-apps`, and originally `nextcloud-data` too — needed `sudo` since they
were owned by `root` or `www-data`, not `di0__0ib`).

**`nextcloud-data` deliberately left at `770` / not writable via Samba.**
Don chose this when asked, since it's the live data directory Nextcloud
itself manages — the concern is that files dropped in from outside Nextcloud's
own file-scanning wouldn't be tracked in its database correctly, unlike the
other shares which are mostly bulk storage without an app managing them.
Verified with a real `smbuser` write test that this share is still,
correctly, not writable through Samba. If read-write access to Nextcloud
files via Samba is ever wanted, the safer route is Nextcloud's own external
storage / WebDAV rather than `chmod`-ing its data folder.

**Verified functionally**, not just via `stat`: ran a real write test as the
`smbuser` unix account (uid 100) *inside* the samba container against a
fixed and an unfixed folder — confirmed the fixed ones accept writes and
`nextcloud-data` correctly still rejects them.

**`.deleted` recycle-bin folders checked across all shares:** only three had
accumulated anything so far (`plex` 4K, `tv` 20K, `j4.5-backup` 4K) — all
negligible, nothing needed cleaning tonight. See the recycle-bin note above
for how to view/clean these if they grow later.
