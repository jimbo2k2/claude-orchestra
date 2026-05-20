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

# Executor template: assert the templated sentence is present WITH the literal sentinel
# (Organiser substitutes at brief-construction time, not at run-launch).
grep -q "This project's task protocol lives at \`__PROTOCOL_FOLDER__\`" "$REPO/lib/executor-prompt-template.txt" || { echo "executor-prompt-template.txt missing the templated sentence with __PROTOCOL_FOLDER__"; exit 1; }
echo "Executor template (literal sentinel present, Organiser-substituted at runtime): PASS"

# Organiser prompt: assert the Organiser-side substitution instruction is present
# (so the Organiser knows to substitute __PROTOCOL_FOLDER__ in executor briefs).
grep -q "executor-prompt-template" "$REPO/lib/organiser-prompt.txt" || { echo "organiser-prompt.txt missing executor-template reference"; exit 1; }
grep -qE "perform the (following )?substitution|substitute.*__PROTOCOL_FOLDER__|mirror what orchestrator" "$REPO/lib/organiser-prompt.txt" || { echo "organiser-prompt.txt missing Organiser-side substitution instruction"; exit 1; }
echo "Organiser substitution-instruction: PASS"

echo "test_protocol_folder: PASS"
