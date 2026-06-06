#!/usr/bin/env bash
set -euo pipefail

uv run ansible-lint deploy.yml tasks/
