# gitlab-mr-review plugin

This plugin helps resolve GitLab MR comments from your current branch.

## What it does

1. Finds the MR for the current branch.
2. Fetches MR comments/discussions.
3. Produces a numbered comment list.
4. Lets you choose which comments to fix.
5. Supports follow-up code fixes in your repo.

## Files

- `.codex-plugin/plugin.json`: Plugin manifest.
- `skills/gitlab-mr-review/SKILL.md`: Codex workflow instructions.
- `scripts/current_branch_mr_comments.sh`: Branch-based MR + comments fetcher.
- `scripts/fetch_mr_review.sh`: Direct MR fetch by URL or project+IID.

## Quick start

```bash
cd ~/plugins/gitlab-mr-review
./scripts/current_branch_mr_comments.sh --state unresolved
```

Then pick comment indexes and rerun:

```bash
cd ~/plugins/gitlab-mr-review
./scripts/current_branch_mr_comments.sh --select 1,3
```
