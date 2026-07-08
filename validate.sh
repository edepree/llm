#!/usr/bin/env bash
set -euo pipefail

uv run ansible-playbook --syntax-check playbook.yml
uv run ansible-lint --strict --profile production playbook.yml roles/
