#!/usr/bin/env bash
set -euo pipefail

DEV_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev)
      DEV_MODE=true
      ;;
  esac
  shift
done

if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

if $DEV_MODE; then
  uv sync --all-groups
  uv run ansible-galaxy collection install -r requirements.yml
  exit 0
fi

uv sync --no-dev
uv run ansible-galaxy collection install -r requirements.yml

read -rp "Target Endpoint (default: lisa.home.arpa): " host
host="${host:-lisa.home.arpa}"

cmd=(
  uv run ansible-playbook
  -i "${host},"
  playbook.yml
)

case "$host" in
  localhost|127.0.0.1)
    cmd+=(--connection=local --ask-become-pass)
    ;;
  *)
    read -rp "Target User (default: ubuntu): " user
    user="${user:-ubuntu}"
    cmd+=(-u "$user" --ask-pass --ask-become-pass)
    ;;
esac

"${cmd[@]}"
