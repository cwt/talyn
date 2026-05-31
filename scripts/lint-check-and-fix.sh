#!/usr/bin/env bash
# Talyn Python Lint Check & Fix Script
# Usage: ./scripts/lint-check-and-fix.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== Talyn Python Lint Check & Fix ==="
echo ""

if ! command -v ruff >/dev/null 2>&1; then
    printf "${RED}Error: 'ruff' is not installed or not in PATH.${NC}\n"
    printf "Please install it via: pip install '.[lint]'\n"
    exit 1
fi

printf "${YELLOW}Running ruff check with automatic fixes (imports & basic rules)...${NC}\n"
if ruff check --select=I,F --fix .; then
    printf "${GREEN}Ruff check successfully ran and fixed issues!${NC}\n"
else
    printf "${RED}Ruff check found issues that could not be automatically fixed.${NC}\n"
    exit 1
fi
