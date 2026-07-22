# Understanding log — code review tool

Design decisions and the *why* behind them. Tick each once you can explain it back.

## Problem
- [ ] Devs want self-service PR reviews without standing up hosted infra or
      handing a service more GitHub/AWS power than they already have. Goal: one
      slash command, runs entirely on the dev's own credentials.

## Constraints that shaped the design
- [ ] Client-side only: the diff comes from the dev's own `gh` auth and the
      models run in the dev's own AWS account. No server, no stored GitHub token,
      no diff leaving the machine except as Bedrock/S3 calls in that account.
- [ ] Terminal delivery (not a PR comment): posting a comment needs a token-auth
      REST call, which would mean giving the tool write credentials. Printing the
      review in-session avoids that entirely — and lets you act on findings on
      the spot.

## Architecture choices
- [ ] CodeBuild over classic Lambda: agentic reviews are long (>15 min cap) and
      idle-heavy (billed waiting on LLM I/O) — worst case for classic Lambda.
- [ ] CodeBuild over Lambda MicroVMs (June 2026): MicroVMs are a *session*
      primitive (snapshot → run-microvm → connect to HTTPS endpoint); our job is
      fire-and-forget batch. MicroVMs parked for an interactive v2.
- [ ] Fan-out/fan-in over agent debate: fixed cost, no convergence-to-agreement
      failure mode, debuggable, and cross-model agreement = confidence signal.
- [ ] Pipeline (review.py) over agents-only: agents are simpler to *build*
      (the loop lives in the model) but harder to *operate* (unbounded cost,
      opaque failures). Hybrid keeps `claude -p` as baseline + one reviewer slot.

## Model roster
- [ ] Anthropic models invoke via `us.` cross-region inference-profile IDs;
      Qwen/DeepSeek via bare model IDs (the `us.` variant is invalid for them).
      "Offered in catalog" ≠ "access enabled" — verify by test-invoking each
      model (~$0.01), and remember the `us.` profiles only route in US regions.

## Account/region discipline
- [ ] Region defaults are a common trap (CLI default, SSO/profile default, and
      the region your models actually live in can all differ). The engine passes
      region to boto3 explicitly when set and otherwise uses your AWS default;
      setup.sh records an explicit region so runs are reproducible.
