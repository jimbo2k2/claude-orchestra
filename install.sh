#!/bin/bash
# install.sh — Install claude-orchestra to a target directory
#
# Usage:
#   ./install.sh                    # installs to ~/claude-scripts/
#   ./install.sh /custom/path       # installs to custom directory
#
# After installation, the 'orchestra' command and all hook scripts
# will be available in the target directory. Add it to your PATH.

set -euo pipefail

INSTALL_DIR="${1:-$HOME/claude-scripts}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing claude-orchestra to $INSTALL_DIR"

mkdir -p "$INSTALL_DIR/templates"

# Copy CLI entry point
cp "$REPO_DIR/bin/orchestra" "$INSTALL_DIR/orchestra"

# Copy lib scripts (hook scripts + orchestrator)
cp "$REPO_DIR/lib/"*.sh "$INSTALL_DIR/"

# Copy templates
cp "$REPO_DIR/templates/"* "$INSTALL_DIR/templates/"

# Make everything executable
chmod +x "$INSTALL_DIR/orchestra" "$INSTALL_DIR/"*.sh

echo ""
echo "Installed successfully!"
echo ""
echo "Add to your PATH (add this to ~/.bashrc or ~/.zshrc):"
echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
echo ""
echo "Quick start:"
echo "  cd /path/to/your/project"
echo "  orchestra init"
echo "  # Edit .orchestra/PLAN.md and .orchestra/TODO.md"
echo "  orchestra run"
