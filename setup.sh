#!/usr/bin/env bash
set -euo pipefail

DEV_MODE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dev) DEV_MODE=true; shift ;;
    *) shift ;;
  esac
done

# install uv (skip if already on PATH)
if ! command -v uv &> /dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  source $HOME/.local/bin/env
fi

if $DEV_MODE; then
  uv sync --all-groups
else
  uv sync --no-dev
  uv run ansible-galaxy collection install -r requirements.yml

  # user input
  read -rp "Target Endpoint (default: localhost): " host
  host="${host:-localhost}"

  # run playbook
  if [[ "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
    uv run ansible-playbook -i "${host}," --connection=local --ask-become-pass deploy.yml
  else
    uv run ansible-playbook -i "${host}," --ask-pass --ask-become-pass deploy.yml
  fi
fi
