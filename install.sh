#!/bin/bash
# install.sh — Bootstrap orchestra into a project
#
# Usage:
#   cd /path/to/your/project
#   /path/to/claude-orchestra/install.sh
#
# This copies orchestra scripts into .orchestra/ making the project
# self-contained. No global installation, no ~/claude-scripts/.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${1:-$(pwd)}"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "ERROR: Directory '$PROJECT_DIR' does not exist" >&2
    exit 1
fi

echo "Bootstrapping orchestra v3 into $PROJECT_DIR/.orchestra/"

# Create directory structure
mkdir -p "$PROJECT_DIR/.orchestra/bin"
mkdir -p "$PROJECT_DIR/.orchestra/hooks"
mkdir -p "$PROJECT_DIR/.orchestra/lib"
mkdir -p "$PROJECT_DIR/.orchestra/sessions/archive"

# Copy scripts
cp "$REPO_DIR/bin/orchestra" "$PROJECT_DIR/.orchestra/bin/orchestra"
cp "$REPO_DIR/lib/orchestrator.sh" "$PROJECT_DIR/.orchestra/bin/orchestrator.sh"
cp "$REPO_DIR/lib/stage-changes.sh" "$PROJECT_DIR/.orchestra/hooks/stage-changes.sh"
cp "$REPO_DIR/lib/config.sh" "$PROJECT_DIR/.orchestra/lib/config.sh"

chmod +x "$PROJECT_DIR/.orchestra/bin/orchestra" "$PROJECT_DIR/.orchestra/bin/orchestrator.sh"
chmod +x "$PROJECT_DIR/.orchestra/hooks/stage-changes.sh"

# Copy templates (only if files don't already exist — don't overwrite customisations)
for f in config config.test HANDOVER.md INBOX.md README.md toolchain.md; do
    if [ ! -f "$PROJECT_DIR/.orchestra/$f" ]; then
        cp "$REPO_DIR/templates/$f" "$PROJECT_DIR/.orchestra/$f"
        echo "   Created .orchestra/$f"
    else
        echo "   Skipped .orchestra/$f (already exists)"
    fi
done

# .orchestra/CLAUDE.md (autonomous session rules)
if [ ! -f "$PROJECT_DIR/.orchestra/CLAUDE.md" ]; then
    cp "$REPO_DIR/templates/orchestra-CLAUDE.md" "$PROJECT_DIR/.orchestra/CLAUDE.md"
    echo "   Created .orchestra/CLAUDE.md"
fi

# Test fixtures (.orchestra/test/) — for `orchestra test` integration test
if [ ! -d "$PROJECT_DIR/.orchestra/test" ]; then
    cp -r "$REPO_DIR/templates/test" "$PROJECT_DIR/.orchestra/test"
    echo "   Created .orchestra/test/ (fixtures for orchestra test)"
fi

# Set up .claude/settings.json (staging hook only, project-local path)
if [ ! -f "$PROJECT_DIR/.claude/settings.json" ]; then
    mkdir -p "$PROJECT_DIR/.claude"
    cp "$REPO_DIR/templates/settings.json" "$PROJECT_DIR/.claude/settings.json"
    echo "   Created .claude/settings.json with staging hook"
else
    echo "   Skipped .claude/settings.json (already exists — check hooks manually)"
fi

# Set up governance directories if they don't exist
for dir_spec in "TODO:TODO.md:TODO-CLAUDE.md" "Decisions:DECISIONS.md:DECISIONS-CLAUDE.md" "Changelog:CHANGELOG.md:CHANGELOG-CLAUDE.md"; do
    IFS=: read -r dir_name main_file claude_file <<< "$dir_spec"
    if [ ! -d "$PROJECT_DIR/$dir_name" ]; then
        mkdir -p "$PROJECT_DIR/$dir_name/archive"
        cp "$REPO_DIR/templates/governance/${main_file%.md}-${dir_name}.md" "$PROJECT_DIR/$dir_name/$main_file" 2>/dev/null \
            || cp "$REPO_DIR/templates/governance/$main_file" "$PROJECT_DIR/$dir_name/$main_file" 2>/dev/null \
            || echo "   WARNING: No template for $dir_name/$main_file"
        cp "$REPO_DIR/templates/governance/$claude_file" "$PROJECT_DIR/$dir_name/CLAUDE.md" 2>/dev/null \
            || echo "   WARNING: No template for $dir_name/CLAUDE.md"
        echo "   Created $dir_name/ with templates"
    else
        echo "   Skipped $dir_name/ (already exists)"
    fi
done

# Append workflow section to CLAUDE.md if not already present
if [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
    if ! grep -q "Multi-Session Autonomous Workflow\|Development Protocol" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
        cat "$REPO_DIR/templates/CLAUDE-workflow.md" >> "$PROJECT_DIR/CLAUDE.md"
        echo "   Appended workflow section to CLAUDE.md"
    else
        echo "   CLAUDE.md already has workflow section"
    fi
fi

# Create DEVELOPMENT-PROTOCOL.md placeholder if not present
if [ ! -f "$PROJECT_DIR/DEVELOPMENT-PROTOCOL.md" ]; then
    if [ -f "$REPO_DIR/templates/DEVELOPMENT-PROTOCOL.md" ]; then
        cp "$REPO_DIR/templates/DEVELOPMENT-PROTOCOL.md" "$PROJECT_DIR/DEVELOPMENT-PROTOCOL.md"
        echo "   Created DEVELOPMENT-PROTOCOL.md from template"
    fi
fi

echo ""
echo "Done! Orchestra is now project-local in .orchestra/"
echo ""
echo "Next steps:"
echo "  1. Edit .orchestra/config — set TASKS, governance paths, WORKTREE_BASE"
echo "  2. Edit .orchestra/toolchain.md — add your build/test commands"
echo "  3. Create DEVELOPMENT-PROTOCOL.md if not already present"
echo "  4. Add T-numbered tasks to TODO/TODO.md"
echo "  5. Run: .orchestra/bin/orchestra run"
echo ""
echo "No global install needed. Everything runs from .orchestra/bin/"
