---
description: Multi-model PR code review (three Bedrock reviewers + a synthesizer)
argument-hint: <PR number, or empty for current branch; add "no-archive" to skip S3>
allowed-tools: Bash(gh pr diff:*), Bash(gh repo view:*), Bash(gh auth status:*), Bash(git rev-parse:*), Bash(git fetch:*), Bash(git diff:*), Bash(git branch:*), Bash(python3 *review.py:*)
---

Run a multi-model code review and present the results.

Steps — follow exactly, do not improvise a review yourself:

1. Confirm we are in a git repo: `git rev-parse --is-inside-work-tree`.
   If it fails, stop and tell the user this must be run inside a git repository.

2. Parse "$ARGUMENTS":
   - The PR number `<pr>` is the first whitespace-separated token if it is a
     positive integer; otherwise there is no PR number (branch mode). A
     non-integer token where a PR number is expected → stop and say so; never
     pass it to a shell command.
   - If the arguments contain `no-archive` or `--no-archive` (or the user asks
     for a sensitive diff not to be stored), turn on no-archive mode for step 4.

3. Get the diff and pick a label (if the diff command fails, stop — do not run
   the engine on a stale or empty diff):
   - PR number `<pr>` given: `gh pr diff <pr> > /tmp/codereview-pr-<pr>.diff`;
     label `PR <pr>`. If this fails with a 404 or auth error, the active gh
     account likely lacks access to this repo — run `gh auth status`, have the
     user switch accounts (`gh auth switch`) if they have more than one, then retry.
   - No PR number: detect the base branch with
     `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`
     (fall back to `main` if that fails), then `git fetch origin` and
     `git diff origin/<base>...HEAD > /tmp/codereview-branch.diff`. Label
     `branch <current branch>` (from `git branch --show-current`).
   - If the diff file is empty, stop and tell the user there is nothing to review.

4. Run the review engine (~4 Bedrock calls in the user's AWS account, a few
   minutes — tell the user it is running). Append `--no-archive` if no-archive
   mode is on:
   `python3 ${CLAUDE_PLUGIN_ROOT}/review.py --diff <diff file> --label "<label>"`

5. Show the user the full consolidated review verbatim, including the token
   usage table and the archive location. Do NOT add your own findings on top —
   the engine's output is the review.

6. Offer to help fix any of the findings in this session.

If step 4 fails with a credentials or "Operation not allowed"/AccessDenied error:
the user's active AWS credentials can't invoke the configured Bedrock models (or
write to the S3 bucket). Point them at `setup.sh`, which detects their account,
lets them pick the models, and generates the least-privilege IAM policy. If they
use a named profile, it must be visible to the session — set it in the config
(`~/.codereview/config.json`) or export `CODEREVIEW_AWS_PROFILE` in `~/.zshenv`
(NOT `~/.zshrc`; Claude Code runs a non-interactive shell that doesn't source it).
