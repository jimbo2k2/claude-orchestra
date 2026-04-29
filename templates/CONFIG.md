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
- `MODEL`: opus
- `EFFORT`: high

## Worktree
- `WORKTREE_BASE`: /tmp/orchestra-myproject
- `BASE_BRANCH`: main

## Tmux
- `TMUX_PREFIX`: orchestra

## Smoke Test
- `SMOKE_TEST_TIMEOUT`: 900
