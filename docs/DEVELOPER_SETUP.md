# Developer Setup — /pr:codereview

One-time setup, ~10 minutes. After this you can run `/pr:codereview <PR>` in any
repo from Claude Code (or opencode) and get a multi-model AI code review that
runs on your own AWS account.

## What you need before starting

- **AWS credentials** for the account you want the models to run in — a named
  profile, SSO session, or the default credential chain all work. The tool uses
  whatever account and region your credentials resolve to.
- **GitHub access** to the repos you review (your normal `gh` login).
- **python3 3.11+** (3.9/3.10 are end-of-life).
- Access to **Amazon Bedrock** models in that account/region. Availability
  varies — "offered in the catalog" ≠ "access enabled". Enable model access in
  the Bedrock console if needed.

---

## Step 0 — Install the CLI tools (skip what you already have)

Check what's present:

```bash
aws --version
gh --version
python3 --version
```

Install anything missing (assumes [Homebrew](https://brew.sh)):

```bash
brew install awscli gh
```

No Homebrew? Use the official installers: [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
and [GitHub CLI](https://github.com/cli/cli#installation).

## Step 1 — Log in to AWS

Use whatever you normally use. A dedicated named profile keeps this separate from
your other AWS setup:

```bash
aws configure --profile codereview
```

Verify you're authenticated (any account/region is fine — the tool reads them):

```bash
aws sts get-caller-identity --profile codereview
```

## Step 2 — Install the Python dependency

```bash
python3 -m pip install boto3
```

## Step 3 — Run the installer

From the repo root:

```bash
./setup.sh
```

It will:

1. Detect your active AWS identity and region (using the profile you point it at).
2. Let you choose the three reviewer models and the synthesizer.
3. Offer to create the S3 log bucket `codereview-logs-<random>` (90-day expiry,
   public access blocked), use an existing bucket, or skip archiving.
4. Generate a least-privilege IAM policy scoped to just those models + bucket,
   and offer to create/attach it (every IAM change is confirmed).
5. Write `~/.codereview/config.json`.

If you chose a named profile, the config records it — no extra environment
variable is required. If you also want the profile visible to ad-hoc shells,
add it to `~/.zshenv` (**not** `~/.zshrc` — Claude Code runs a non-interactive
shell that sources `~/.zshenv` only):

```bash
echo 'export CODEREVIEW_AWS_PROFILE=codereview' >> ~/.zshenv
```

## Step 4 — Log in the GitHub CLI (skip if already done)

```bash
gh auth status
```

If not logged in:

```bash
gh auth login
```

## Step 5 — Install the plugin (Claude Code)

Inside a Claude Code session:

```
/plugin marketplace add jaycp30/codereview-ai-plugin
/plugin install pr@codereview-ai
```

Restart Claude Code (or start a new session) and `/pr:codereview` appears in the
slash-command list.

**opencode instead?** Copy `opencode/codereview.md` from this repo into your
opencode commands directory, and copy `plugins/pr/review.py` to
`~/.codereview/review.py` (that command expects this path).

## Step 6 — Run your first review

Open any repo in Claude Code, then (plugin commands are namespaced as
`plugin:command` — type `/pr` and let autocomplete finish it):

```
/pr:codereview 123
```

Use a real PR number, or run it with no argument to review your current branch
against the default branch. The run takes a few minutes (3 models review in
parallel, a 4th merges their findings) and costs roughly $0.10–0.50 in Bedrock
usage depending on diff size.

You get the consolidated review in your session — findings flagged by 2+ models
are high-confidence — and you can immediately ask Claude to fix any finding.
Every review is also archived (with its input diff) to
`s3://<your-bucket>/reviews/<timestamp>_<pr>_<your-iam-user>/`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Unknown command` | The command is namespaced: `/pr:codereview`. If still missing, run `/plugin` to check it's installed+enabled, then `/reload-plugins`. |
| `AWS account … is not approved` | You set an account allowlist (`account_id`) and the active credentials point elsewhere. Switch profiles, or clear `account_id` / `CODEREVIEW_AWS_ACCOUNT_ID` to allow any account. |
| `AccessDenied` / `Operation not allowed` on Bedrock or S3 | Your credentials can't invoke the configured models or write the bucket. Re-run `setup.sh` and apply the generated IAM policy, and check the models are enabled in the Bedrock console. |
| `Unable to locate credentials` | Not logged in, or the profile name is wrong. Redo Step 1. |
| `The provided model identifier is invalid` | The model ID isn't valid in your region (e.g. a `us.` profile outside a US region). Re-run `setup.sh` and pick region-appropriate IDs. |
| `HTTP 404` / `gh: Not Found` from `gh pr diff` | Your GitHub login lacks access to that repo, wrong PR number, or the wrong `gh` account is active (`gh auth switch`). |
| "nothing to review" | The diff is empty — your branch has no changes vs the base branch. |
| `ModuleNotFoundError: boto3` | Step 2, with the same python3 you run elsewhere. |
| Profile not picked up inside Claude Code | Set it in `~/.codereview/config.json`, or export `CODEREVIEW_AWS_PROFILE` in `~/.zshenv` (not `~/.zshrc`), then fully relaunch Claude Code. |
