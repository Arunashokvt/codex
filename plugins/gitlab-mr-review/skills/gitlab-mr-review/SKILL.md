---
name: gitlab-mr-review
description: Find the MR for the current branch, fetch MR comments, ask which comments to fix, and implement those fixes.
---

# GitLab MR Review

Use this skill when the user wants to resolve MR review comments from the current branch.

## Required workflow

1. Run `glab mr list --source-branch $(git branch --show-current)`.
2. Identify the MR for the current branch (if multiple are returned, show options and let user pick).
3. Run `glab mr comment list <mr-iid>` and gather all comments.
4. Present comments as a numbered list and ask the user which comment numbers should be fixed.
5. Implement fixes in the local codebase for the selected comments.
6. Summarize each selected comment and the corresponding code change.

## Helper script

Use `./scripts/current_branch_mr_comments.sh` to automate steps 1-3 and produce structured JSON.

Examples:

```bash
# Fetch MR + all comments for current branch
./scripts/current_branch_mr_comments.sh

# Only unresolved comments
./scripts/current_branch_mr_comments.sh --state unresolved

# Mark selected comments in output payload
./scripts/current_branch_mr_comments.sh --select 1,3,5
```

## Notes for fixing comments

- Prefer unresolved comments first unless user says otherwise.
- Use comment file/line metadata when available.
- If a comment is general and lacks file context, inspect MR diff/context before editing.
- After edits, run relevant tests or checks when feasible.
