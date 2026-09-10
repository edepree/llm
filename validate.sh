#!/usr/bin/env bash
set -euo pipefail

uv run --no-sync ansible-playbook --syntax-check playbook.yml
uv run --no-sync ansible-lint --offline --strict --profile production playbook.yml roles/
