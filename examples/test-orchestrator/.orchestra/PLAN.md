# Plan

## Objective
Build a small CLI utility toolkit — a set of bash scripts for common dev tasks.
This is a test project to validate the autonomous orchestrator workflow.

## Background
This project exists purely to exercise the multi-session orchestrator, hooks,
state file updates, and decision logging. The scripts themselves are trivial.

## Requirements
- R1: `scripts/greet.sh` takes a name as its first argument and prints a greeting
- R2: `scripts/greet.sh` prints a usage message and exits non-zero if no argument given
- R3: `scripts/password.sh` generates a random password and prints it to stdout
- R4: `scripts/password.sh` accepts an optional length argument (default if not provided)
- R5: `scripts/password.sh` must use a character set that includes uppercase, lowercase, and digits at minimum — the exact set is YOUR CHOICE (document your decision in .orchestra/DECISIONS.md)
- R6: `scripts/password.sh` default length is YOUR CHOICE — pick something sensible and document why in .orchestra/DECISIONS.md
- R7: `scripts/sysinfo.sh` prints system information to stdout
- R8: `scripts/sysinfo.sh` must display at least 4 metrics — which metrics to show is YOUR CHOICE (document in .orchestra/DECISIONS.md)
- R9: All scripts use `set -euo pipefail`
- R10: A `README.md` describes each script with usage examples

## Architecture
```
scripts/
├── greet.sh      — greeting utility
├── password.sh   — random password generator
└── sysinfo.sh    — system information display
tests/
└── run.sh        — test runner (pre-written, do not modify)
README.md
```

## Non-Goals
- No interactive prompts — all input via arguments
- No external dependencies — pure bash, standard coreutils only
- No colour output or formatting beyond plain text

## Acceptance Criteria
- AC1: All tests in `bash tests/run.sh` pass
- AC2: `scripts/greet.sh Alice` outputs a greeting containing "Alice"
- AC3: `scripts/password.sh` outputs a string of the chosen default length
- AC4: `scripts/password.sh 20` outputs a 20-character string
- AC5: `scripts/sysinfo.sh` outputs at least 4 lines of system information
- AC6: `README.md` exists and is non-empty
- AC7: .orchestra/DECISIONS.md contains at least 2 entries (character set choice, default length choice, and/or metric choice)

## Task Breakdown
- [ ] Create scripts/greet.sh — greeting with name argument, usage error if missing (R1, R2)
- [ ] Create scripts/password.sh — random password generator with configurable length (R3, R4, R5, R6). Document character set and default length decisions in .orchestra/DECISIONS.md
- [ ] Create scripts/sysinfo.sh — display at least 4 system metrics (R7, R8). Document metric choices in .orchestra/DECISIONS.md
- [ ] Create README.md describing each script with usage examples (R10)
