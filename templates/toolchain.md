# Toolchain — React Native + Expo + Supabase

## Prerequisites
These system tools must be available before orchestra runs. Init validates them.
- node (>=18)
- npx

## Build & Serve
```
npx expo start --web
```

## UI Capture (Playwright — headless Chromium)

### Setup (once per build phase, during scaffold task)
```
npm install -D playwright && npx playwright install chromium --with-deps
```

### Capture command
Saves screenshots to `.captures/` (gitignored).
```
node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  await page.goto(process.argv[1], { waitUntil: 'networkidle' });
  await page.screenshot({ path: process.argv[2], fullPage: true });
  await browser.close();
})();
" "URL" "OUTPUT_PATH"
```
Replace `URL` (e.g. `http://localhost:8081/`) and `OUTPUT_PATH`
(e.g. `.captures/home-screen.png`).

### Verification workflow (mandatory for every UI task)
1. Start dev server if not already running
2. For each screen affected by the task:
   a. Capture screenshot at target viewport
   b. Read the screenshot file (Claude Read tool — multimodal vision)
   c. Evaluate against Standing AC > Visual & Layout criteria
   d. Check for: clipping, overflow, missing elements, wrong colours, broken layout
3. If any check fails → enter debug pass (max 3 iterations)
4. If all checks pass → mark task complete

### Structural verification
After screenshot, query DOM for expected elements:
```
node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  await page.goto(process.argv[1], { waitUntil: 'networkidle' });
  const testIds = await page.locator('[data-testid]').evaluateAll(
    els => els.map(e => ({ testId: e.dataset.testid, tag: e.tagName, visible: e.offsetParent !== null }))
  );
  console.log(JSON.stringify(testIds, null, 2));
  await browser.close();
})();
" "URL"
```

### Screenshots directory
- `.captures/` is gitignored — screenshots are ephemeral per-session artifacts
- Naming convention: `{screen-name}.png` (e.g. `home-screen.png`, `timeline-tab.png`)

## Data Verification
- Use `supabase-js` to query target tables after mutations
- Verify RLS policies allow/deny as expected for current user role
- Check optimistic updates revert cleanly on simulated failure

## Conventions
- File naming: see project CLAUDE.md and PUBLISHED-LANGUAGE.md
- Component structure: see toolchain-specific conventions in project docs
