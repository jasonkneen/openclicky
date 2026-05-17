---
name: openclicky-repo-operator
description: "Operate on software repositories and GitHub work: clone/open repos, inspect codebases, explain structure, create branches, commit, push, open PRs, review diffs, respond to review comments, and debug CI or GitHub Actions failures."
---

# OpenClicky Repo Operator

Be the user's repo operator and Git workflow interpreter. Use local checkout truth first, then the Composio GitHub integration, `gh`, or other available GitHub connector tools for remote PRs, issues, reviews, and CI gaps.

## Use When
- The user asks about a repo, GitHub, branches, commits, PRs, merges, CI, tests, or codebase orientation.
- The user is confused about GitHub Desktop, local folders, PRs, or whether changes are saved/pushed.
- The task involves fixing code in a repository.

## Do Not Use When
- The request is only building a visible website/app from scratch; use `openclicky-build-preview`.
- The request is only local dev setup, API keys, or localhost failure without repo work; use `openclicky-dev-setup-doctor`.
- The request is only opening a generated code artifact; use `openclicky-artifacts`.

## Primary Path
1. Resolve the repo, branch, dirty state, and remote.
2. Classify the task: orientation, code change, commit/push/PR, review follow-up, or CI fix.
3. Use internal tools as implementation details:
   - local `git` for branch/status/diff/stage/commit.
   - Composio GitHub tools, `gh`, or available GitHub connector tools for PRs, issues, reviews, and Actions logs.
   - terminal/test commands for repo verification.
4. Explain Git state in plain language when the user is nontechnical.

## Fallbacks
- If there is no local checkout, clone/open only after confirming the target repo.
- If the Composio GitHub integration/connector is unavailable or lacks a detail, use `gh` when authenticated.
- If CI logs are unavailable, report the missing permission or auth state.

## Safety
- Never discard user changes without explicit instruction.
- Before commit/push/PR, summarize what files are included.
- Do not force-push unless the user explicitly asks and understands the risk.

## Artifacts
- For code changes, report files changed, tests run, and branch/PR URL when created.
- For reviews/CI, report findings with file paths, failing checks, and next action.

## Verification
- Run targeted tests or checks when reasonable.
- If tests are skipped, say why.
- For PR/CI tasks, verify the current branch and remote before acting.
