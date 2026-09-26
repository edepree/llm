#!/usr/bin/env bash
set -euo pipefail

if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

if [[ ${1:-} == --dev ]]; then uv sync --all-groups; else uv sync --no-dev; fi
uv run ansible-galaxy collection install -r requirements.yml
if [[ ${1:-} == --dev ]]; then exit 0; fi

read -rp "Target Endpoint (default: host.example.com): " host
host="${host:-host.example.com}"

cmd=(uv run ansible-playbook -i "${host}," playbook.yml --ask-become-pass)

case "$host" in
  localhost|127.0.0.1)
    cmd+=(--connection=local)
    ;;
  *)
    read -rp "Target User (default: ubuntu): " user
    cmd+=(-u "${user:-ubuntu}" --ask-pass)
    ;;
esac

"${cmd[@]}"
