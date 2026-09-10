#!/usr/bin/env bash
# ============================================================================
# RETRO HOMELAB — GitHub auto-sync (config backup, secrets stripped)
#
# Backs up your homelab CONFIG (nginx, docker-compose.yml, docs, scripts) into
# a dedicated subfolder of your existing "retrohomelab" GitHub Pages repo —
# the same repo that serves your live retrohomelab.dev site — WITHOUT ever
# touching the site's own files (index.html, CNAME, heartjournal/, etc).
#
# How this works:
#   - Your live homelab config stays right where it is: $HOMELAB_DIR
#     (default ~/homelab) — nothing about that folder changes.
#   - A SEPARATE local clone of your "retrohomelab" repo is kept at
#     $SITE_REPO_DIR (default ~/retrohomelab-site).
#   - Each sync copies (mirrors) $HOMELAB_DIR into a subfolder of that clone
#     ($SITE_REPO_DIR/$SUBFOLDER, default "homelab-config"), then commits and
#     pushes ONLY that subfolder — every other file in the repo (your actual
#     site) is left completely alone.
#   - Secrets are stripped at the copy step (rsync --exclude) AND blocked
#     again by a .gitignore inside that subfolder AND scanned for again right
#     before every push. Three layers, on purpose, because this repo is public.
#
# Usage:
#   bash github-sync.sh setup   # one-time: clone the repo, configure git
#   bash github-sync.sh all     # mirror, stage, scan, commit, and push
#   bash github-sync.sh status  # show what would be synced without pushing
#
# Safe to re-run: setup is idempotent (skips steps already done).
# ============================================================================
set -euo pipefail

HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
SITE_REPO_DIR="${SITE_REPO_DIR:-$HOME/retrohomelab-site}"
SUBFOLDER="${SUBFOLDER:-homelab-config}"
CONFIG_FILE="$HOMELAB_DIR/.github-sync.env"   # holds GITHUB_USER / GITHUB_REPO / GITHUB_TOKEN — chmod 600, never copied into the repo

# ----------------------------------------------------------------------------
# Colors (falls back to plain text if not a terminal)
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
fi
info()  { echo "${C_GREEN}[github-sync]${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}[github-sync] WARNING:${C_RESET} $*"; }
die()   { echo "${C_RED}[github-sync] ERROR:${C_RESET} $*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------------
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. Run: sudo apt install -y $1"; }

check_deps() {
  require_cmd git
  require_cmd curl
  require_cmd rsync
}

# ----------------------------------------------------------------------------
# The exact list of things that never get synced, in one place. Used both as
# rsync --exclude flags (so secrets are never even copied onto disk in the
# site repo's working tree) and as the subfolder's .gitignore (a second,
# independent layer in case a file ever slips past the rsync excludes).
# ----------------------------------------------------------------------------
EXCLUDE_PATTERNS=(
  ".git"
  ".env*"
  ".github-sync.env*"
  "config/credentials.txt*"
  "**/credentials.txt*"
  ".megarc*"
  "**/.megarc*"
  "*.key"
  "*.pem"
  "*_rsa"
  "*_rsa.pub"
  "*_ed25519"
  "*_ed25519.pub"
  "nginx/certs/"
  "**/certs/"
  "*.crt"
  "data/"
  "volumes/"
  "**/nextcloud-data/"
  "**/immich-photos/"
  "**/media/"
  "**/mega-sync/"
  "**/backups/"
  "*.db"
  "*.sqlite"
  "*.sqlite3"
)

rsync_exclude_args() {
  local args=()
  for p in "${EXCLUDE_PATTERNS[@]}"; do
    args+=("--exclude=$p")
  done
  printf '%s\n' "${args[@]}"
}

write_subfolder_gitignore() {
  {
    echo "# --- NEVER remove these lines. This is what keeps secrets out of a PUBLIC repo. ---"
    printf '%s\n' "${EXCLUDE_PATTERNS[@]}"
    echo "# --- end protected section ---"
  } > "$SITE_REPO_DIR/$SUBFOLDER/.gitignore"
  info "Wrote $SITE_REPO_DIR/$SUBFOLDER/.gitignore"
}

# ----------------------------------------------------------------------------
# Pre-push safety net: scan whatever's about to be committed, in OUR subfolder
# only, for anything that LOOKS like a live secret. Defense in depth.
# ----------------------------------------------------------------------------
scan_staged_for_secrets() {
  local diff added filtered hits

  diff=$(git -C "$SITE_REPO_DIR" diff --cached -U0 -- "$SUBFOLDER" 2>/dev/null || true)

  # Only look at ADDED lines (skip diff headers/context lines).
  added=$(printf '%s\n' "$diff" | grep -E '^\+' || true)

  # Drop lines that are clearly just a variable NAME or a well-known
  # non-secret placeholder — never an actual credential value. A normal
  # docker-compose.yml is full of "PASSWORD: ${SOME_VAR}"-style lines, which
  # name a variable but never contain the real value (that only exists in
  # .env, which is excluded before it ever gets this far). Flagging every one
  # of those buries any real hit in noise.
  filtered=$(printf '%s\n' "$added" | grep -Eiv \
    '\$\{[A-Za-z0-9_]+\}|process\.env\.[A-Za-z0-9_]+|changeme|change_me|REDACTED|<[a-z0-9 _-]+>|xxxxxxxx|\*{3,}' \
    || true)

  hits=$(printf '%s\n' "$filtered" | grep -Ein \
    'password[[:space:]]*[:=]|api[_-]?key[[:space:]]*[:=]|secret[[:space:]]*[:=]|BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|token[[:space:]]*[:=][^,]*[A-Za-z0-9]{16,}' \
    || true)

  if [[ -n "$hits" ]]; then
    warn "Staged changes contain text that looks like a secret. Refusing to push. Review below, fix it, then re-run:"
    echo "$hits" | sed 's/^/    /'
    return 1
  fi
  return 0
}

# Figures out the repo's actual default branch (don't assume "main" — this
# repo already existed before this script touched it).
current_branch() {
  git -C "$SITE_REPO_DIR" symbolic-ref --short HEAD
}

# ----------------------------------------------------------------------------
# setup — one-time: load/collect credentials, clone the site repo, prep the
# subfolder. Safe to re-run.
# ----------------------------------------------------------------------------
cmd_setup() {
  check_deps
  mkdir -p "$HOMELAB_DIR"

  # Leftover from an earlier, abandoned approach (a standalone repo living
  # directly in $HOMELAB_DIR) — no longer used, safe to remove.
  if [[ -d "$HOMELAB_DIR/.git" ]]; then
    rm -rf "$HOMELAB_DIR/.git" "$HOMELAB_DIR/.gitignore"
    info "Removed leftover .git/.gitignore from $HOMELAB_DIR (from the old standalone-repo approach — no longer used)."
  fi

  if [[ -f "$CONFIG_FILE" ]]; then
    info "$CONFIG_FILE already exists — reusing saved GitHub username/repo/token."
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  else
    read -rp "GitHub username: " GITHUB_USER
    read -rp "Repo name [retrohomelab]: " GITHUB_REPO
    GITHUB_REPO="${GITHUB_REPO:-retrohomelab}"
    read -rp "Repo visibility, public or private [public]: " GITHUB_VISIBILITY
    GITHUB_VISIBILITY="${GITHUB_VISIBILITY:-public}"
    echo "Paste your GitHub Personal Access Token (classic, 'repo' scope)."
    echo "Create one at: https://github.com/settings/tokens"
    read -rsp "Token (input hidden): " GITHUB_TOKEN
    echo

    cat > "$CONFIG_FILE" <<EOF
GITHUB_USER="$GITHUB_USER"
GITHUB_REPO="$GITHUB_REPO"
GITHUB_VISIBILITY="$GITHUB_VISIBILITY"
GITHUB_TOKEN="$GITHUB_TOKEN"
EOF
    chmod 600 "$CONFIG_FILE"
    info "Saved credentials to $CONFIG_FILE (chmod 600 — never synced anywhere, excluded from the repo)."
  fi

  [[ -n "${GITHUB_TOKEN:-}" ]] || die "No token found in $CONFIG_FILE. Delete that file and re-run setup."

  # Confirm the repo exists (create it ONLY if it genuinely doesn't — this
  # script never deletes or recreates a repo that's already there).
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}")
  if [[ "$http_code" == "404" ]]; then
    info "Repo ${GITHUB_USER}/${GITHUB_REPO} doesn't exist yet — creating it (${GITHUB_VISIBILITY})..."
    local private_flag="false"
    [[ "$GITHUB_VISIBILITY" == "private" ]] && private_flag="true"
    curl -s -X POST \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      https://api.github.com/user/repos \
      -d "{\"name\":\"${GITHUB_REPO}\",\"private\":${private_flag}}" \
      > /dev/null
    info "Repo created: https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
  elif [[ "$http_code" == "200" ]]; then
    info "Repo ${GITHUB_USER}/${GITHUB_REPO} already exists — reusing it as-is."
  else
    die "Unexpected response ($http_code) checking for the repo. Check your token has 'repo' scope."
  fi

  local remote_url="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git"

  if [[ ! -d "$SITE_REPO_DIR/.git" ]]; then
    info "Cloning ${GITHUB_USER}/${GITHUB_REPO} into $SITE_REPO_DIR ..."
    git clone "$remote_url" "$SITE_REPO_DIR"
  else
    info "$SITE_REPO_DIR already exists — refreshing its remote URL and pulling latest."
    git -C "$SITE_REPO_DIR" remote set-url origin "$remote_url"
    git -C "$SITE_REPO_DIR" pull --ff-only
  fi

  mkdir -p "$SITE_REPO_DIR/$SUBFOLDER"
  write_subfolder_gitignore

  info "Setup complete. This will sync INTO: $SITE_REPO_DIR/$SUBFOLDER"
  info "(the rest of that repo — your actual site files — is never touched)"
  info "Run: bash $(basename "$0") all"
}

# ----------------------------------------------------------------------------
# all — mirror $HOMELAB_DIR into the subfolder, stage ONLY that subfolder,
# scan, commit, push.
# ----------------------------------------------------------------------------
cmd_all() {
  local force=0
  [[ "${1:-}" == "--force" ]] && force=1

  check_deps
  [[ -f "$CONFIG_FILE" ]] || die "Not set up yet. Run: bash $(basename "$0") setup"
  [[ -d "$SITE_REPO_DIR/.git" ]] || die "Site repo not found at $SITE_REPO_DIR. Run: bash $(basename "$0") setup"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  git -C "$SITE_REPO_DIR" pull --ff-only || die "Couldn't fast-forward $SITE_REPO_DIR — someone/something else changed the repo in a conflicting way. Check it manually before re-running."

  mkdir -p "$SITE_REPO_DIR/$SUBFOLDER"

  # IMPORTANT: rsync's --delete only removes destination files that are
  # missing from the source — it leaves excluded files alone rather than
  # deleting them. --delete-excluded is what actually purges anything in the
  # destination that matches an --exclude pattern (e.g. secret files that
  # were copied over before the exclude list was correct). Without it, a
  # secret file that ever made it into $SITE_REPO_DIR/$SUBFOLDER once would
  # sit there forever, un-deletable by later runs no matter how the excludes
  # were fixed.
  mapfile -t EXCLUDE_ARGS < <(rsync_exclude_args)
  rsync -a --delete --delete-excluded "${EXCLUDE_ARGS[@]}" "$HOMELAB_DIR"/ "$SITE_REPO_DIR/$SUBFOLDER"/

  # Written AFTER rsync on purpose: rsync's --delete would otherwise remove
  # this file immediately, since it doesn't exist in $HOMELAB_DIR (the
  # source) and wasn't itself in the exclude list.
  write_subfolder_gitignore

  git -C "$SITE_REPO_DIR" add -A -- "$SUBFOLDER"

  if git -C "$SITE_REPO_DIR" diff --cached --quiet -- "$SUBFOLDER"; then
    info "Nothing to sync — no changes since last push."
    return 0
  fi

  if ! scan_staged_for_secrets; then
    if [[ "$force" -eq 1 ]]; then
      warn "--force given: pushing anyway. Only do this after reading every line above yourself and confirming none of it is a real credential value."
    else
      die "Secret scan failed. Nothing was pushed. If you've read the lines above and they're genuinely safe (variable references, doc text, placeholders — not real values), re-run with: bash $(basename "$0") all --force"
    fi
  fi

  git -C "$SITE_REPO_DIR" commit -m "homelab-config auto-sync $(date -u '+%Y-%m-%d %H:%M UTC')" >/dev/null
  local branch; branch="$(current_branch)"
  git -C "$SITE_REPO_DIR" push origin "$branch"
  info "Pushed to https://github.com/${GITHUB_USER}/${GITHUB_REPO}/tree/${branch}/${SUBFOLDER}"
}

# ----------------------------------------------------------------------------
# status — mirror + show what would be committed, without committing/pushing.
# ----------------------------------------------------------------------------
cmd_status() {
  [[ -d "$SITE_REPO_DIR/.git" ]] || die "Site repo not found at $SITE_REPO_DIR. Run: bash $(basename "$0") setup"

  mkdir -p "$SITE_REPO_DIR/$SUBFOLDER"

  mapfile -t EXCLUDE_ARGS < <(rsync_exclude_args)
  rsync -a --delete --delete-excluded "${EXCLUDE_ARGS[@]}" "$HOMELAB_DIR"/ "$SITE_REPO_DIR/$SUBFOLDER"/

  write_subfolder_gitignore

  echo "Files that would be synced (respecting exclusions), under $SUBFOLDER/ only:"
  git -C "$SITE_REPO_DIR" status -- "$SUBFOLDER"
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
case "${1:-}" in
  setup)  cmd_setup ;;
  all)    cmd_all "${2:-}" ;;
  status) cmd_status ;;
  *)
    echo "Usage: bash $(basename "$0") {setup|all|status}"
    echo "       bash $(basename "$0") all --force   # push even if the secret scan flags something, once you've reviewed it yourself"
    exit 1
    ;;
esac
