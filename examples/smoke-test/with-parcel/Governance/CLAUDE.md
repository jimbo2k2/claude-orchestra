# Governance — Pending Parcels Protocol (smoke-test fixture)

This is a minimal version of the parcel-mode protocol used to exercise
the wind-down's parcel-mode detection in `orchestra test with-parcel`.

A real project's `Governance/CLAUDE.md` will be much longer (see the
LogRings repo's version). What matters for the smoke test is:

- The file exists with this name and location.
- `Governance/pending/` exists as a folder (kept by `.gitkeep`).
- The file describes a parcel format with at least the four section
  headings (`## Task`, `## Decisions`, `## Changelog`, `## Bugs`).

## Parcel file shape

```markdown
---
hex: a3f1c2
created: 2026-05-05
source: <branch or run identifier>
---

## Task

(Optional. One per parcel.)

## Decisions

(Optional. Multiple allowed; positional handles `D-1`, `D-2`, …)

## Changelog

(Optional. One per parcel.)

## Bugs

(Optional. Multiple allowed; positional handles `B-1`, `B-2`, …)
```

## Hex

Six lowercase hex chars, locally generated (`openssl rand -hex 3`).

## Wind-down responsibility

Orchestra wind-down's job ends at parcel creation + merge. Allocating
real T/D/C/B numbers and inserting them into the four governance files
on `main` is the parent project's wrap-up step (W4) — not orchestra's.
