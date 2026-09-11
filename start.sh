#!/usr/bin/env bash
# Idempotent bootstrap for a fresh VM: installs system deps, sets up a
# venv, prompts for secrets (once), and runs the identity-repo sync
# server. Safe to re-run — every step checks current state first.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

log() { printf '\n==> %s\n' "$1"; }

OS="$(uname -s)"

ensure_system_deps() {
  if [[ "$OS" == "Linux" ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      local missing=()
      for pkg in python3 python3-venv python3-pip git; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        log "Installing missing packages: ${missing[*]}"
        sudo apt-get update -y
        sudo apt-get install -y "${missing[@]}"
      else
        log "System packages already present"
      fi
    elif command -v yum >/dev/null 2>&1; then
      local missing=()
      for pkg in python3 python3-pip git; do
        rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        log "Installing missing packages: ${missing[*]}"
        sudo yum install -y "${missing[@]}"
      else
        log "System packages already present"
      fi
    else
      log "Unrecognized Linux package manager — skipping system package install; ensure python3, pip, venv and git are installed manually."
    fi
  elif [[ "$OS" == "Darwin" ]]; then
    if ! command -v brew >/dev/null 2>&1; then
      echo "Homebrew not found. Install it from https://brew.sh, then re-run this script." >&2
      exit 1
    fi
    for pkg in python3 git; do
      brew list "$pkg" >/dev/null 2>&1 || { log "Installing $pkg"; brew install "$pkg"; }
    done
  else
    log "Unrecognized OS '$OS' — skipping system package install."
  fi
}

ensure_git_repo() {
  git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "This directory is not a git repo. Clone this repo properly before running start.sh." >&2
    exit 1
  }
  git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1 || {
    echo "No 'origin' remote configured on this clone." >&2
    exit 1
  }
}

ensure_venv() {
  if [[ ! -d "$REPO_DIR/.venv" ]]; then
    log "Creating virtualenv"
    python3 -m venv "$REPO_DIR/.venv"
  else
    log "Virtualenv already exists"
  fi
  log "Installing/updating Python dependencies"
  "$REPO_DIR/.venv/bin/pip" install --quiet --upgrade pip
  "$REPO_DIR/.venv/bin/pip" install --quiet -r "$REPO_DIR/requirements.txt"
}

default_github_org() {
  local url
  url="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
  echo "$url" | sed -E 's#^git@github\.com:##; s#^https?://github\.com/##; s#\.git$##; s#/.*##'
}

prompt_with_default() {
  local var_name="$1" prompt_text="$2" default_val="${3:-}"
  local value
  if [[ -n "$default_val" ]]; then
    read -r -p "$prompt_text [$default_val]: " value
    value="${value:-$default_val}"
  else
    read -r -p "$prompt_text: " value
  fi
  printf -v "$var_name" '%s' "$value"
}

ensure_env_file() {
  if [[ -f "$REPO_DIR/.env" ]]; then
    log ".env already exists"
    read -r -p "Re-enter secrets and overwrite .env? [y/N]: " redo
    [[ "$redo" =~ ^[Yy]$ ]] || return 0
  fi

  log "Enter secrets (written to .env, chmod 600, never committed to git)"
  prompt_with_default OKTA_DOMAIN "Okta domain (e.g. dev-12345678.okta.com)"
  echo "GitHub bot PAT: use a fine-grained token scoped ONLY to the org below,"
  echo "with Administration:write (create repos) + Contents:write (push) permissions."
  read -r -s -p "GitHub bot PAT (input hidden): " GITHUB_PAT
  echo
  prompt_with_default GITHUB_ORG "GitHub org where per-user repos get created" "$(default_github_org)"
  prompt_with_default SYNC_PORT "Port for sync server" "5000"
  prompt_with_default SYNC_HOST "Bind address" "0.0.0.0"

  ( umask 177
    cat > "$REPO_DIR/.env" <<EOF
OKTA_DOMAIN=$OKTA_DOMAIN
GITHUB_PAT=$GITHUB_PAT
GITHUB_ORG=$GITHUB_ORG
SYNC_PORT=$SYNC_PORT
SYNC_HOST=$SYNC_HOST
EOF
  )
  chmod 600 "$REPO_DIR/.env"
  log "Wrote .env (chmod 600)"
}

SERVICE_INSTALLED=0

offer_systemd_service() {
  [[ "$OS" == "Linux" ]] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0

  if systemctl list-unit-files 2>/dev/null | grep -q '^surface-sync.service'; then
    log "surface-sync.service is already installed"
    read -r -p "Restart it now? [y/N]: " restart
    [[ "$restart" =~ ^[Yy]$ ]] && sudo systemctl restart surface-sync
    SERVICE_INSTALLED=1
    return 0
  fi

  read -r -p "Install as a systemd service so it survives reboots/SSH disconnects? [y/N]: " install_svc
  [[ "$install_svc" =~ ^[Yy]$ ]] || return 0

  sed -e "s#__REPO_DIR__#$REPO_DIR#g" -e "s#__RUN_USER__#$(whoami)#g" \
    "$REPO_DIR/systemd/surface-sync.service.template" | sudo tee /etc/systemd/system/surface-sync.service >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable --now surface-sync
  log "Installed and started surface-sync.service"
  SERVICE_INSTALLED=1
}

ensure_system_deps
ensure_git_repo
ensure_venv
ensure_env_file
offer_systemd_service

if [[ "$SERVICE_INSTALLED" -eq 1 ]]; then
  log "Sync server is running under systemd. Check status with: systemctl status surface-sync"
else
  log "Starting sync server in the foreground (Ctrl+C to stop)"
  set -a
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
  set +a
  exec "$REPO_DIR/.venv/bin/python" "$REPO_DIR/app.py"
fi
