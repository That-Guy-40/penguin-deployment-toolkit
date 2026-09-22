#!/bin/bash
# 00-bootstrap.sh - Initialize project structure and create config.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Windows 11 Install Bootstrap ==="
echo "Project root: $PROJECT_ROOT"

# Create directory structure
echo "Creating directory structure..."
mkdir -p "$PROJECT_ROOT/pxe"
mkdir -p "$PROJECT_ROOT/http/winpe"
mkdir -p "$PROJECT_ROOT/answer"
mkdir -p "$PROJECT_ROOT/vms"

# Check if config.sh already exists. Otherwise copy it from the single-source-of-
# truth template (config.sh.example) — no duplicated heredoc to drift out of sync.
if [[ -f "$PROJECT_ROOT/config.sh" ]]; then
    echo "config.sh already exists. Keeping existing configuration."
elif [[ -f "$PROJECT_ROOT/config.sh.example" ]]; then
    echo "Creating config.sh from config.sh.example..."
    cp "$PROJECT_ROOT/config.sh.example" "$PROJECT_ROOT/config.sh"
    chmod +x "$PROJECT_ROOT/config.sh"
    echo "Created config.sh (set ISO_PATH, or run scripts/00b-download-iso.sh)"
else
    echo "ERROR: config.sh.example not found; cannot create config.sh" >&2
    exit 1
fi

echo ""
echo "Bootstrap complete!"
echo ""
echo "Next steps:"
echo "  1. Edit config.sh and set ISO_PATH to your Windows 11 ISO"
echo "  2. Run 01-install-deps.sh to install dependencies"
echo "  3. Run remaining scripts in order"
