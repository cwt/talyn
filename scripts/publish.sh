#!/usr/bin/env bash
# Talyn PyPI Publishing Script
# Usage: ./scripts/publish.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DIST_DIR="./dist"

echo "=== Talyn PyPI Publisher ==="
echo ""

# 1. Verify that twine is installed
if ! command -v twine >/dev/null 2>&1; then
    printf "${YELLOW}twine was not found in PATH.${NC}\n"
    printf "Attempting to install twine using current user pip...\n"
    pip install --user twine || {
        printf "${RED}Failed to install twine. Please install it manually with: pip install twine${NC}\n"
        exit 1
    }
fi

# 2. Check if .pypirc config exists
if [ ! -f "$HOME/.pypirc" ] && [ -z "${TWINE_PASSWORD:-}" ]; then
    printf "${YELLOW}Warning: Neither ~/.pypirc nor TWINE_PASSWORD environment variable was found.${NC}\n"
    printf "Twine will prompt you for your credentials interactively.\n"
    printf "Remember: Username should be '__token__' and Password should be your pypi- token.\n\n"
fi

# 3. Check if wheels exist in dist/
if [ ! -d "$DIST_DIR" ] || [ -z "$(ls -A "$DIST_DIR" 2>/dev/null)" ]; then
    printf "${RED}Error: No built wheels found in %s!${NC}\n" "$DIST_DIR"
    printf "Please run './scripts/build.sh' first to compile the package wheels.\n"
    exit 1
fi

printf "${YELLOW}The following package distributions will be uploaded to PyPI:${NC}\n"
ls -lh "$DIST_DIR"
echo ""

read -r -p "Do you want to proceed with publishing to PyPI? [y/N] " response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    printf "${GREEN}Uploading package wheels via twine...${NC}\n"
    twine upload "$DIST_DIR"/*
    printf "\n${GREEN}Successfully uploaded all packages to PyPI!${NC}\n"
else
    printf "${YELLOW}Publishing canceled.${NC}\n"
    exit 0
fi
