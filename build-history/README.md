# Build history

Per-version design + implementation artifacts that produced this codebase.
Layout matches `claude-maestro`'s convention.

```
build-history/
└── archive/
    └── <version>/
        ├── <date>-<topic>.md            design briefs, specs, plans
        ├── RESUME.md                    handover notes between sessions (if any)
        └── claude-transcripts/          JSONL exports of the Claude sessions
            └── <session-name>.jsonl
```

Active design work in progress (if any) lives in `build-history/<topic>/`
at the top level; once shipped, the directory is moved into
`archive/<version>/`.

The current contents are frozen historical record. Internal cross-refs
inside the archived docs point to paths that existed at the time of
writing (e.g. `docs/superpowers/specs/`); those paths have since been
restructured to this `build-history/` shape.

The canonical "what does the code actually do now" reference is `CLAUDE.md`
at repo root, the spec under `archive/v0-cleanup/`, and the code itself.
