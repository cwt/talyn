#!/usr/bin/env bash
# Talyn Code Formatter Script (Python)
# Usage: ./scripts/code-format.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=== Talyn Code Formatter (Python) ==="
echo ""

# 1. Format Python using Ruff (fast, Black-compatible)
if command -v ruff >/dev/null 2>&1; then
    printf "${YELLOW}Formatting Python files with Ruff...${NC}\n"
    ruff format .
    printf "${GREEN}Python files successfully formatted!${NC}\n"
else
    printf "${RED}Warning: 'ruff' is not installed. Skipping Python formatting.${NC}\n"
    printf "Please install it via: pip install '.[lint]'\n"
fi
