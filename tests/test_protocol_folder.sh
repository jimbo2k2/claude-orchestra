#!/bin/bash
# PROTOCOL_FOLDER substitution per spec § 3.8 + § 8.1.
# Prong A: non-empty PROTOCOL_FOLDER substitutes the path into the two
#          orchestrator-substituted prompts (organiser + winddown).
# Prong B: empty PROTOCOL_FOLDER deletes the templated sentence line from
#          those two prompts.
# Executor template: only asserted to CONTAIN the templated sentence with the
#                    literal __PROTOCOL_FOLDER__ placeholder (Organiser
#                    handles its substitution at brief-construction time).

set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

# Helper: replicate orchestrator.sh's substitution pipeline for a given
# template + PROTOCOL_FOLDER value.
construct_prompt() {
    local template="$1"
    local protocol_folder="$2"
    if [ -n "$protocol_folder" ]; then
        sed "s|__RUN_DIR__|/tmp/runs/test|g" "$template" \
            | sed "s|__PROTOCOL_FOLDER__|$protocol_folder|g"
    else
        sed "s|__RUN_DIR__|/tmp/runs/test|g" "$template" \
            | sed '/__PROTOCOL_FOLDER__/d'
    fi
}

# Prong A: non-empty PROTOCOL_FOLDER (orchestrator-substituted prompts)
for tmpl in lib/organiser-prompt.txt lib/winddown-prompt.txt; do
    out=$(construct_prompt "$REPO/$tmpl" "Development/conventions/")
    echo "$out" | grep -q "Development/conventions/" || { echo "Prong A: $tmpl missing path"; exit 1; }
    echo "$out" | grep -q "__PROTOCOL_FOLDER__" && { echo "Prong A: $tmpl has unsubstituted sentinel"; exit 1; } || true
done
echo "Prong A (non-empty PROTOCOL_FOLDER, orchestrator-substituted): PASS"

# Prong B: empty PROTOCOL_FOLDER (orchestrator-substituted prompts)
for tmpl in lib/organiser-prompt.txt lib/winddown-prompt.txt; do
    out=$(construct_prompt "$REPO/$tmpl" "")
    echo "$out" | grep -q "__PROTOCOL_FOLDER__" && { echo "Prong B: $tmpl has unsubstituted sentinel"; exit 1; } || true
    echo "$out" | grep -q "This project's task protocol lives at" && { echo "Prong B: $tmpl still contains the templated sentence"; exit 1; } || true
done
echo "Prong B (empty PROTOCOL_FOLDER, orchestrator-substituted): PASS"

# Executor template (LEGACY Agent-tool path): still ships with the literal sentinel sentence.
# Post lr-tmux swap it is ORPHANED — the lr-tmux dispatch path does NOT use it; the assertion
# documents that the legacy template is unchanged, not that it is live.
grep -q "This project's task protocol lives at \`__PROTOCOL_FOLDER__\`" "$REPO/lib/executor-prompt-template.txt" || { echo "executor-prompt-template.txt missing the templated sentence with __PROTOCOL_FOLDER__"; exit 1; }
echo "Executor template (legacy literal sentinel present): PASS"

# Organiser prompt (lr-tmux path): worker task files carry NO protocol pointer — the lr-* worker
# reads the project cascade itself — so the Organiser no longer does brief-time __PROTOCOL_FOLDER__
# substitution. Assert the new contract states this, and that the removed mirror-substitution block
# is gone.
grep -qi "carry no protocol pointer" "$REPO/lib/organiser-prompt.txt" || { echo "organiser-prompt.txt missing the 'no protocol pointer' worker-task-file contract"; exit 1; }
grep -qE "mirror what orchestrator" "$REPO/lib/organiser-prompt.txt" && { echo "organiser-prompt.txt still carries the removed executor-brief substitution block"; exit 1; } || true
echo "Organiser worker-task-file contract (no protocol pointer): PASS"

echo "test_protocol_folder: PASS"
