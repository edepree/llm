#!/usr/bin/env bash
set -euo pipefail

uv run ansible-playbook --syntax-check deploy.yml
uv run ansible-lint deploy.yml tasks/
uv run yamllint --strict deploy.yml tasks/ templates/
