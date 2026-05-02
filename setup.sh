#!/bin/bash
set -euo pipefail

# install uv if not already present
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh

# setup python and ansible environment
uv sync
uv run ansible-galaxy collection install -r requirements.yml
