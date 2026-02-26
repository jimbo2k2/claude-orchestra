# Plan

This document is the contract between the human planning phase and autonomous
execution. It is produced during an interactive session with the user and should
be comprehensive enough that an autonomous Claude session can resolve ambiguity
by referencing it — without needing to ask clarifying questions.

PLAN.md is READ-ONLY during autonomous execution. Only the human modifies it.

## Objective
<!-- One paragraph: what are we building and why? -->

## Background
<!-- Context the executing sessions need: what exists today, what problem this
     solves, relevant history, links to external docs or specs -->

## Requirements
<!-- Specific, testable statements of what the system must do.
     Number them so TODO tasks and acceptance criteria can reference them.
     e.g. R1: The API must return 404 for unknown user IDs -->

## Architecture
<!-- Components, data flow, key files/directories, integration points.
     Include enough detail that Claude knows WHERE to put things,
     not just WHAT to build. -->

## Non-Goals
<!-- Things explicitly out of scope. Prevents gold-plating and scope creep.
     e.g. "No admin UI in this phase", "Don't migrate existing data" -->

## Acceptance Criteria
<!-- How to verify the plan is fully implemented. These should be concrete
     and checkable — the verify hook will evaluate progress against them.
     e.g. AC1: All tests pass
          AC2: GET /users/:id returns user object matching schema
          AC3: Division by zero returns HTTP 400, not 500 -->

## Task Breakdown
<!-- Ordered list of tasks to copy into TODO.md. Each task should be
     completable in a single Claude session (aim for 1-15 minutes of work).
     Reference requirements where relevant.
     e.g. - [ ] Create user model and migration (R1, R2)
          - [ ] Add GET /users/:id endpoint with 404 handling (R3)
          - [ ] Write tests for user endpoints (AC1, AC2) -->
