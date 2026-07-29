# Issue tracker: GitHub

Issues and PRDs for this repository live as GitHub Issues in `coolhwm/quill-vault`. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --repo coolhwm/quill-vault --title "..." --body "..."`. Use a heredoc for multiline bodies.
- **Read an issue**: `gh issue view <number> --repo coolhwm/quill-vault --comments`, including labels and comments when gathering context.
- **List issues**: `gh issue list --repo coolhwm/quill-vault --state open --json number,title,body,labels,comments` with appropriate label and state filters.
- **Comment on an issue**: `gh issue comment <number> --repo coolhwm/quill-vault --body "..."`
- **Apply or remove labels**: use `gh issue edit <number> --repo coolhwm/quill-vault --add-label "..."` or `--remove-label "..."`.
- **Close an issue**: `gh issue close <number> --repo coolhwm/quill-vault --comment "..."`

## Pull requests as a triage surface

**PRs as a request surface: no.**

Do not include pull requests in triage discovery. If a pull request is named explicitly, resolve it with `gh pr view <number>` and operate on it with the corresponding `gh pr` commands.

GitHub shares one number space across issues and pull requests. For an ambiguous bare reference such as `#42`, try `gh pr view 42 --repo coolhwm/quill-vault` and fall back to `gh issue view 42 --repo coolhwm/quill-vault`.

## When a skill says “publish to the issue tracker”

Create a GitHub Issue in `coolhwm/quill-vault` with `gh issue create`.

## When a skill says “fetch the relevant ticket”

Run `gh issue view <number> --repo coolhwm/quill-vault --comments`.

## Wayfinding operations

The `/wayfinder` skill represents a map as one GitHub Issue with child issues as decision tickets.

- **Map**: create one issue labelled `wayfinder:map`, containing the Notes, Decisions-so-far, and Fog sections.
- **Child ticket**: link the issue to the map as a GitHub sub-issue. If sub-issues are unavailable, add it to a task list in the map and put `Part of #<map>` at the top of the child. Apply a `wayfinder:<type>` label where type is `research`, `prototype`, `grilling`, or `task`.
- **Blocking edge**: prefer GitHub native issue dependencies. Resolve the blocker database ID with `gh api repos/coolhwm/quill-vault/issues/<number> --jq .id`, then call `gh api --method POST repos/coolhwm/quill-vault/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`. If dependencies are unavailable, add `Blocked by: #<number>` to the child body.
- **Frontier query**: list the map's open child issues in map order, then exclude issues with an open blocker or an assignee. The first remaining issue is the frontier.
- **Claim**: run `gh issue edit <number> --repo coolhwm/quill-vault --add-assignee @me`. Claiming is the session's first tracker write.
- **Resolve**: comment the decision or result, close the child issue, then append a context pointer to the map's Decisions-so-far section.
