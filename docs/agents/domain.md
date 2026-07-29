# Domain Docs

How engineering skills should consume this repository's domain documentation.

## Before exploring, read these

- `CONTEXT.md` at the repository root.
- `CONTEXT-MAP.md` at the repository root if it exists; it points to the relevant context-specific `CONTEXT.md` files.
- Relevant architectural decisions under `docs/adr/`.
- In a multi-context repository, relevant decisions under `src/<context>/docs/adr/`.

If any of these files do not exist, proceed silently. Do not create empty placeholders. Use the domain-modeling workflow when a term or durable decision needs to be recorded.

## File structure

This is a single-context repository:

```text
/
├── CONTEXT.md
├── docs/
│   └── adr/
└── QuillvaultDemo/
```

Introduce `CONTEXT-MAP.md` and context-scoped `CONTEXT.md` files only if the repository later becomes a genuine multi-context monorepo.

## Use the glossary's vocabulary

Use the canonical vocabulary from `CONTEXT.md` in specifications, tickets, code, tests, and review findings. Do not drift to synonyms that the glossary explicitly marks with `Avoid`.

If a required concept is absent, first reconsider whether the project already has a suitable term. If it is a genuine domain gap, record it through the domain-modeling workflow.

## Flag ADR conflicts

Surface conflicts with an existing ADR explicitly instead of silently overriding it. Identify the ADR and explain why reopening the decision may be justified.
