#!/usr/bin/env bash

# install uv (skip if already on PATH)
if ! command -v uv &> /dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  source $HOME/.local/bin/env
fi

# setup python and ansible environment
uv sync
uv run ansible-galaxy install -r requirements.yml

# run playbook
# read -rp "Domain [ntfy.example.com]: " DOMAIN
# uv run ansible-playbook playbook.yml -i localhost, -e "domain=${DOMAIN:-ntfy.example.com}"