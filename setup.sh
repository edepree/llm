#!/usr/bin/env bash
set -euo pipefail

# user input
read -rp "Target Endpoint (default: localhost): " host
host="${host:-localhost}"

# install uv (skip if already on PATH)
if ! command -v uv &> /dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  source $HOME/.local/bin/env
fi

uv sync
uv run ansible-galaxy collection install -r requirements.yml

# run playbook
if [[ "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
  uv run ansible-playbook -i "${host}," --connection=local --ask-become-pass deploy.yml
else
  uv run ansible-playbook -i "${host}," --ask-pass --ask-become-pass deploy.yml
fi
