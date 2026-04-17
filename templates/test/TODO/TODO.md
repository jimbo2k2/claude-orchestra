# TODO (test)

Test governance file for orchestra integration test. This file is committed
to the repo and reset before each test run.

### T9998 — Orchestra integration test task 1

- **Module:** Test
- **Status:** `[ ]` OPEN
- **Detail:** Append the line `# Test session 1: <UTC timestamp>` to `.orchestra/test/test-artifacts.md` (create the file if it doesn't exist). Then mark this task COMPLETE in this TODO file and write a C-entry in `.orchestra/test/Changelog/CHANGELOG.md`.
- **AC:**
  - [ ] File `.orchestra/test/test-artifacts.md` contains the session 1 marker line
  - [ ] T9998 marked COMPLETE in this file
  - [ ] C-entry written for T9998

### T9999 — Orchestra integration test task 2

- **Module:** Test
- **Status:** `[ ]` OPEN
- **Detail:** Append the line `# Test session 2: <UTC timestamp>` to `.orchestra/test/test-artifacts.md`. The file should already exist from T9998 — if it doesn't, the session-branch accumulation failed and you should flag BLOCKED. Then mark this task COMPLETE and write a C-entry.
- **AC:**
  - [ ] File `.orchestra/test/test-artifacts.md` contains BOTH session markers
  - [ ] T9999 marked COMPLETE in this file
  - [ ] C-entry written for T9999

<!-- Next number: T10000 -->
