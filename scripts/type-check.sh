#!/usr/bin/env bash
# Talyn Python Static Type Check Script
# Usage: ./scripts/type-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== Talyn Python Static Type Check ==="
echo ""

if ! command -v mypy >/dev/null 2>&1; then
    printf "${RED}Error: 'mypy' is not installed or not in PATH.${NC}\n"
    printf "Please install it via: pip install '.[lint]'\n"
    exit 1
fi

printf "${YELLOW}Running mypy on talyn source directory...${NC}\n"
if mypy talyn; then
    printf "${GREEN}Type checking completed successfully! No issues found.${NC}\n"
else
    printf "${RED}Type checking failed. Please check the errors above.${NC}\n"
    exit 1
fi
