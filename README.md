# codereview-ai

Self-service multi-model PR code review. Type `/pr:codereview <PR>` inside
Claude Code (or opencode); three LLMs on **your** Amazon Bedrock review the diff
independently, a fourth merges their findings, the result prints in the session
and is archived to S3.

```
/pr:codereview 123
   1. gh pr diff 123 > diff              — your own GitHub login
   2. review.py                          — your own AWS credentials
        ├─ "review this diff" → reviewer 1  ┐
        ├─ "review this diff" → reviewer 2  ├─ parallel, independent
        └─ "review this diff" → reviewer 3  ┘
        └─ "merge these 3"   → synthesizer  (fan-in)
   3. review prints in your session; ask "fix finding #2" to act on it
   4. archived: s3://<your-bucket>/reviews/<YYYYMMDDHHMMSS>_<pr>_<iam-user>/
```

No servers, no stored GitHub credentials: the diff comes from your machine via
your own auth; the models run in **your** AWS account. By default the tool uses
whatever account and region your active AWS credentials resolve to — nothing is
hardcoded. Findings flagged by 2+ models are marked high-confidence; solo
findings are labeled "(single reviewer)".

## Quick start

1. Clone this repo.
2. Run the interactive installer — it detects your AWS account, lets you pick the
   Bedrock models, optionally creates the S3 log bucket, and generates a
   least-privilege IAM policy:

   ```bash
   ./setup.sh
   ```

3. Install the plugin in Claude Code (see below), or use it standalone.

Full walkthrough: [docs/DEVELOPER_SETUP.md](docs/DEVELOPER_SETUP.md).

## Configuration

`setup.sh` writes `~/.codereview/config.json`. You can also set (or override) any
value with an environment variable — **env var > config file > built-in default**.

| Env var | Config key | What it is |
|---|---|---|
| `CODEREVIEW_AWS_PROFILE` | `profile` | named AWS profile (optional; unset = default credential chain) |
| `CODEREVIEW_AWS_REGION` | `region` | region for Bedrock/S3 (optional; unset = your AWS default) |
| `CODEREVIEW_AWS_ACCOUNT_ID` | `account_id` | if set, the **only** account allowed to run reviews (fail-closed guard; unset = use the active account) |
| `CODEREVIEW_S3_BUCKET` | `s3_bucket` | bucket reviews are archived to (unset = archiving skipped) |
| `CODEREVIEW_SYNTHESIZER` | `synthesizer` | synthesizer model ID |
| — | `reviewers` | map of `{ name: model_id }` for the three reviewers |
| `CODEREVIEW_CONFIG` | — | path to the config file (default `~/.codereview/config.json`) |

Example `~/.codereview/config.json`:

```json
{
  "reviewers": {
    "claude-sonnet-5": "us.anthropic.claude-sonnet-5",
    "qwen3-coder-next": "qwen.qwen3-coder-next",
    "deepseek-v3.2": "deepseek.v3.2"
  },
  "synthesizer": "us.anthropic.claude-opus-4-8",
  "region": "us-east-1",
  "s3_bucket": "codereview-logs-ab12cd34"
}
```

> **Model IDs & regions.** Anthropic models are invoked via the `us.`
> cross-region inference-profile prefix; Qwen/DeepSeek use bare IDs (the `us.`
> variant is invalid for them). The `us.` profiles only route in US regions — if
> your default region isn't `us-*`, pick models available there. Availability
> also varies by account: "offered in the catalog" ≠ "access enabled". `setup.sh`
> prints the commands to list what your account can actually call.

## Install — Claude Code

```
/plugin marketplace add jaycp30/codereview-ai-plugin
/plugin install pr@codereview-ai
```

Restart Claude Code (or start a new session) and `/pr:codereview` appears in the
slash-command list.

## Install — opencode

Copy `opencode/codereview.md` into your opencode commands directory and
`plugins/pr/review.py` to `~/.codereview/review.py` (the opencode command
references that path).

## Prerequisites (once per dev)

1. `gh` CLI logged in to your GitHub account.
2. `python3` **3.11+** with boto3 (`python3 -m pip install boto3`).
3. AWS credentials for the account you want the models to run in. Run `setup.sh`
   to configure the models, bucket, and IAM policy.

## Standalone (no AI tool)

```bash
git diff origin/main...HEAD > code_changes.diff
python3 plugins/pr/review.py --diff code_changes.diff --label "PR 123"
```

Add `--no-archive` to skip the S3 upload entirely — use it for diffs that may
contain secrets or otherwise shouldn't leave the machine. This is advisory AI
review, not a security gate: treat multi-model agreement as a strong signal,
not proof a change is safe.

## Browsing past reviews

```bash
aws s3 ls s3://<your-bucket>/reviews/
aws s3 cp s3://<your-bucket>/reviews/<prefix>/review.md .
```

Tip: using `-` as the destination instead of `.` prints the review to the
terminal without saving a file.

Each run stores `review.md` + `input.diff`; objects expire after 90 days (the
lifecycle rule `setup.sh` applies). Every review also states its own archive
location in its final section, with a ready-made download command.

## Design notes

- **Fan-out/fan-in, not agent debate**: fixed cost (exactly 4 model calls per
  run), independent perspectives, cross-model agreement as a confidence signal.
- **Best-effort archive**: S3 upload failure warns but never sinks a review.
- **Fail-closed identity**: the run verifies AWS credentials before any diff is
  sent to Bedrock. An optional account allowlist (`account_id`) additionally
  refuses to run outside a chosen account.
- **Cost**: roughly $0.10–0.50 per review depending on diff size and models;
  token usage is printed at the end of every run.
- **Region**: passed to boto3 explicitly when set; otherwise your AWS default is
  used. Set it in config to avoid surprises if your CLI default differs.
- See `understanding.md` for the full decision log (why not Lambda, CodeBuild,
  GitHub Actions/Apps/PATs, agent debate, etc.).

## Repo layout

| Path | Purpose |
|---|---|
| `setup.sh` | interactive installer/configurator |
| `.claude-plugin/marketplace.json` | Claude Code marketplace manifest |
| `plugins/pr/` | the plugin: command + review engine |
| `plugins/pr/review.py` | the multi-model pipeline (the whole engine) |
| `plugins/pr/tests/` | pytest suite (mocked Bedrock/S3/STS) |
| `opencode/codereview.md` | opencode flavor of the command |
| `sample.diff` | planted-bug test fixture |
| `understanding.md` | design-decision log |
