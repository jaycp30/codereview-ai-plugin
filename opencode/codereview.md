---
description: Multi-model PR code review (three Bedrock reviewers + a synthesizer)
---

Run a multi-model code review and present the results. The PR number is: $ARGUMENTS

Steps — follow exactly, do not improvise a review yourself:

1. Confirm we are inside a git repository. If not, stop and say so.
2. Get the diff:
   - If a PR number was given: `gh pr diff <number> > /tmp/codereview.diff`
   - If no argument: `git diff origin/main...HEAD > /tmp/codereview.diff`
   - If the diff is empty, stop and tell the user there is nothing to review.
3. Run the review engine (makes ~4 Bedrock calls in your AWS account, takes a few
   minutes): `python3 ~/.codereview/review.py --diff /tmp/codereview.diff --label "PR $ARGUMENTS"`
4. Show the full consolidated review verbatim, including the token usage table.
   Do NOT add your own findings on top — the engine's output is the review.
5. Offer to help fix any of the findings in this session.
