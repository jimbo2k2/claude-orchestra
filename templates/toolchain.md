# Toolchain — React Native + Expo + Supabase

## Build & Serve
```
npx expo start --web
```

## UI Capture
- Tool: Puppeteer (headless Chrome)
- Viewport: 393x852 (iPhone 15 Pro)
- Navigate via `data-testid` selectors
- Screenshot for visual verification
- DOM query for structural verification

## Data Verification
- Use `supabase-js` to query target tables after mutations
- Verify RLS policies allow/deny as expected for current user role
- Check optimistic updates revert cleanly on simulated failure

## Conventions
- File naming: see project CLAUDE.md and PUBLISHED-LANGUAGE.md
- Component structure: see toolchain-specific conventions in project docs
