# Orchestra Configuration

Edit values below. Lines outside the `KEY: VALUE` bullets are ignored.

## Session Limits
- `MAX_SESSIONS`: 10
- `MAX_CONSECUTIVE_CRASHES`: 3
- `MAX_HANG_SECONDS`: 1200

## Quota Pacing
- `QUOTA_PACING`: true
- `QUOTA_THRESHOLD`: 80
- `QUOTA_POLL_INTERVAL`: 120

## Cooldowns (seconds)
- `COOLDOWN_SECONDS`: 15
- `CRASH_COOLDOWN_SECONDS`: 30

## Model
- `ORGANISER_MODEL`: opus
- `EFFORT`: high
- `ORGANISER_CONTEXT_THRESHOLD`: 75

`ORGANISER_MODEL` controls the model the Organiser runs as in each
working session. Subagent Executors choose their own model per task.
`ORGANISER_CONTEXT_THRESHOLD` is the integer percent of the Organiser's
context window at which it should wind itself down and HANDOVER (range
50–95).

The legacy key `MODEL` is still accepted as a deprecated alias and will
be removed in a future release. If you have an older CONFIG.md, rename
`MODEL` to `ORGANISER_MODEL`.

## Worktree
- `WORKTREE_BASE`: /tmp/orchestra-myproject
- `BASE_BRANCH`: main

## Tmux
- `TMUX_PREFIX`: orchestra

## Smoke Test
- `SMOKE_TEST_TIMEOUT`: 900
