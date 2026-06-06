#!/usr/bin/env bash
set -euo pipefail

uv run ansible-playbook --syntax-check deploy.yml
uv run ansible-lint --strict --profile production deploy.yml tasks/
