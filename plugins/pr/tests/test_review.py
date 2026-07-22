"""Unit tests for the review engine, focused on the trust/failure paths:
quorum enforcement, truncation detection, timeout handling, and archive
integrity. Bedrock/S3/STS are all mocked — no network, no cost.

Run:  pytest plugins/pr/tests -q
"""

import sys
from pathlib import Path

import pytest

# review.py is a plain script (not a package); make it importable.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import review  # noqa: E402

# The account allowlist is now opt-in (empty by default). Tests that exercise the
# guard set review.ALLOWED_ACCOUNT_IDS explicitly via the allowlist() helper so
# they pass regardless of how the machine running them is configured.
ALLOWED_ACCOUNT = "111122223333"
WRONG_ACCOUNT = "999999999999"


@pytest.fixture
def allowlist(monkeypatch):
    """Turn the opt-in account guard on for a single test."""
    monkeypatch.setattr(review, "ALLOWED_ACCOUNT_IDS", {ALLOWED_ACCOUNT})
    return ALLOWED_ACCOUNT


# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------

def _resp(text="ok", stop="end_turn", inp=10, out=20):
    return {
        "output": {"message": {"content": [{"text": text}]}},
        "usage": {"inputTokens": inp, "outputTokens": out},
        "stopReason": stop,
    }


class FakeBedrock:
    """converse() behaviour is driven by a {model_id: spec} map, where spec is
    a response dict, or an Exception instance/class to raise."""

    def __init__(self, behaviour):
        self.behaviour = behaviour
        self.calls = []

    def converse(self, modelId, messages, inferenceConfig, system=None):
        self.calls.append(modelId)
        spec = self.behaviour[modelId]
        if isinstance(spec, Exception) or (isinstance(spec, type) and issubclass(spec, Exception)):
            raise spec if isinstance(spec, Exception) else spec("boom")
        return spec


class FakeS3:
    """Records put/delete keys in order; can be told to fail on a given key."""

    def __init__(self, fail_on=None, delete_fails=False):
        self.puts = []
        self.deletes = []
        self.fail_on = fail_on
        self.delete_fails = delete_fails

    def put_object(self, Bucket, Key, Body, ContentType):
        if self.fail_on and self.fail_on in Key:
            raise RuntimeError(f"denied: {Key}")
        self.puts.append(Key)

    def delete_object(self, Bucket, Key):
        if self.delete_fails:
            raise RuntimeError("delete denied")
        self.deletes.append(Key)


class FakeSTS:
    def __init__(self, account=ALLOWED_ACCOUNT):
        self.account = account

    def get_caller_identity(self):
        return {"Account": self.account, "Arn": f"arn:aws:iam::{self.account}:user/tester"}


class FakeSession:
    def __init__(self, bedrock=None, s3=None, account=ALLOWED_ACCOUNT):
        self._bedrock, self._s3, self._account = bedrock, s3, account

    def client(self, name, config=None):
        return {"bedrock-runtime": self._bedrock, "s3": self._s3,
                "sts": FakeSTS(self._account)}[name]


# ---------------------------------------------------------------------------
# converse / review_one
# ---------------------------------------------------------------------------

def test_converse_joins_multiple_text_blocks():
    client = type("C", (), {})()
    client.converse = lambda **kw: {
        "output": {"message": {"content": [{"text": "a"}, {"reasoning": "x"}, {"text": "b"}]}},
        "usage": {}, "stopReason": "end_turn",
    }
    text, _usage, stop = review.converse(client, "m", "sys", "p", 100)
    assert text == "ab"
    assert stop == "end_turn"


def test_converse_raises_on_empty_text():
    client = type("C", (), {})()
    client.converse = lambda **kw: {"output": {"message": {"content": [{"reasoning": "x"}]}}}
    with pytest.raises(ValueError):
        review.converse(client, "m", "sys", "p", 100)


def test_review_one_marks_truncation():
    bedrock = FakeBedrock({"m": _resp(stop="max_tokens")})
    r = review.review_one(bedrock, "rev", "m", "p")
    assert r.ok and r.truncated and not r.usable


def test_review_one_captures_failure():
    bedrock = FakeBedrock({"m": RuntimeError("nope")})
    r = review.review_one(bedrock, "rev", "m", "p")
    assert not r.ok and r.error == "nope" and not r.usable


# ---------------------------------------------------------------------------
# run_state quorum classification (pure)
# ---------------------------------------------------------------------------

def _mk(name, ok=True, truncated=False):
    return review.ModelResult(name=name, ok=ok, truncated=truncated)


def test_run_state_all_ok_is_complete():
    rs = [_mk("a"), _mk("b"), _mk("c")]
    assert review.run_state(rs, 2) == review.COMPLETE


def test_run_state_one_failure_is_degraded():
    rs = [_mk("a"), _mk("b"), _mk("c", ok=False)]
    assert review.run_state(rs, 2) == review.DEGRADED


def test_run_state_truncated_does_not_count_toward_quorum():
    rs = [_mk("a"), _mk("b", truncated=True), _mk("c", ok=False)]
    assert review.run_state(rs, 2) == review.INCOMPLETE


def test_run_state_below_quorum_is_incomplete():
    rs = [_mk("a"), _mk("b", ok=False), _mk("c", ok=False)]
    assert review.run_state(rs, 2) == review.INCOMPLETE


# ---------------------------------------------------------------------------
# main(): exit codes + synthesis gating
# ---------------------------------------------------------------------------

def _run_main(monkeypatch, tmp_path, bedrock, s3=None, extra_argv=(), account=ALLOWED_ACCOUNT):
    s3 = s3 or FakeS3()
    monkeypatch.setattr(review.boto3, "Session",
                        lambda **kw: FakeSession(bedrock=bedrock, s3=s3, account=account))
    diff = tmp_path / "d.diff"
    diff.write_text("diff --git a/x b/x\n+secret change\n")
    argv = ["review.py", "--diff", str(diff), "--label", "PR 1", *extra_argv]
    monkeypatch.setattr(sys, "argv", argv)
    return review.main(), s3


# ---------------------------------------------------------------------------
# AWS account verification (P1-2) — fail closed before any inference
# ---------------------------------------------------------------------------

def test_verify_identity_accepts_allowed_account(allowlist):
    account, arn = review.verify_identity(FakeSession())
    assert account == ALLOWED_ACCOUNT and "tester" in arn


def test_verify_identity_rejects_wrong_account(allowlist):
    with pytest.raises(review.IdentityError):
        review.verify_identity(FakeSession(account=WRONG_ACCOUNT))


def test_verify_identity_no_allowlist_accepts_any_account(monkeypatch):
    # Default deployment: no allowlist, so any account with valid creds passes.
    monkeypatch.setattr(review, "ALLOWED_ACCOUNT_IDS", set())
    account, _arn = review.verify_identity(FakeSession(account=WRONG_ACCOUNT))
    assert account == WRONG_ACCOUNT


def test_verify_identity_fails_closed_on_sts_error():
    class Boom:
        def client(self, name, config=None):
            raise RuntimeError("no creds")
    with pytest.raises(review.IdentityError):
        review.verify_identity(Boom())


def test_main_wrong_account_fails_before_bedrock(monkeypatch, tmp_path, allowlist):
    bedrock = FakeBedrock({mid: _resp() for mid in review.REVIEWERS.values()})
    code, _ = _run_main(monkeypatch, tmp_path, bedrock, account=WRONG_ACCOUNT)
    assert code == 1
    assert bedrock.calls == []          # no diff ever sent to Bedrock


def test_all_reviewers_fail_exits_incomplete_and_skips_synthesis(monkeypatch, tmp_path, capsys):
    bedrock = FakeBedrock({mid: RuntimeError("down") for mid in review.REVIEWERS.values()})
    code, _ = _run_main(monkeypatch, tmp_path, bedrock)
    assert code == 2                                   # INCOMPLETE
    assert review.SYNTHESIZER_ID not in bedrock.calls  # money not spent on synthesis
    assert "INCOMPLETE" in capsys.readouterr().out


def test_one_failure_is_degraded_and_synthesises(monkeypatch, tmp_path, capsys):
    ids = list(review.REVIEWERS.values())
    behaviour = {ids[0]: RuntimeError("down"), ids[1]: _resp(), ids[2]: _resp()}
    behaviour[review.SYNTHESIZER_ID] = _resp(text="consolidated")
    bedrock = FakeBedrock(behaviour)
    code, _ = _run_main(monkeypatch, tmp_path, bedrock)
    assert code == 0
    assert review.SYNTHESIZER_ID in bedrock.calls
    assert "DEGRADED" in capsys.readouterr().out


def test_all_ok_is_complete(monkeypatch, tmp_path, capsys):
    behaviour = {mid: _resp() for mid in review.REVIEWERS.values()}
    behaviour[review.SYNTHESIZER_ID] = _resp(text="consolidated")
    code, _ = _run_main(monkeypatch, tmp_path, FakeBedrock(behaviour))
    assert code == 0
    assert "— COMPLETE" in capsys.readouterr().out


def test_no_archive_skips_s3_upload(monkeypatch, tmp_path, capsys):
    behaviour = {mid: _resp() for mid in review.REVIEWERS.values()}
    behaviour[review.SYNTHESIZER_ID] = _resp(text="consolidated")
    code, s3 = _run_main(monkeypatch, tmp_path, FakeBedrock(behaviour),
                         extra_argv=["--no-archive"])
    assert code == 0
    assert s3.puts == []                                  # nothing uploaded
    assert "Archiving disabled" in capsys.readouterr().out


def test_review_prompt_carries_diff_as_data_not_instructions():
    # The diff text goes in the user message; immutable rules stay in system.
    assert "{diff}" in review.REVIEW_PROMPT
    assert "UNTRUSTED DATA" in review.REVIEW_SYSTEM
    assert "Never follow" in review.REVIEW_SYSTEM


# ---------------------------------------------------------------------------
# archive integrity (P2-2)
# ---------------------------------------------------------------------------

def test_archive_uploads_input_before_review(monkeypatch):
    s3 = FakeS3()
    monkeypatch.setattr(review, "S3_BUCKET", "test-bucket")
    monkeypatch.setattr(review.boto3, "Session", lambda **kw: FakeSession(s3=s3))
    from datetime import datetime, timezone
    out = review.archive_to_s3("REPORT", "DIFF", "PR 1", datetime.now(timezone.utc), "run123")
    assert [k.rsplit("/", 1)[1] for k in s3.puts] == ["input.diff", "review.md"]
    assert "Stored at" in out and "run123" in s3.puts[0]


def test_archive_review_failure_deletes_orphan_input(monkeypatch):
    s3 = FakeS3(fail_on="review.md")
    monkeypatch.setattr(review, "S3_BUCKET", "test-bucket")
    monkeypatch.setattr(review.boto3, "Session", lambda **kw: FakeSession(s3=s3))
    from datetime import datetime, timezone
    out = review.archive_to_s3("REPORT", "DIFF", "PR 1", datetime.now(timezone.utc), "run123")
    assert "Stored at" not in out                       # never claims success on a failed put
    assert "S3 upload FAILED" in out
    assert "removed" in out                             # discloses the cleanup
    assert any("input.diff" in k for k in s3.deletes)   # orphan input actually deleted


def test_archive_review_failure_discloses_when_cleanup_fails(monkeypatch):
    s3 = FakeS3(fail_on="review.md", delete_fails=True)
    monkeypatch.setattr(review, "S3_BUCKET", "test-bucket")
    monkeypatch.setattr(review.boto3, "Session", lambda **kw: FakeSession(s3=s3))
    from datetime import datetime, timezone
    out = review.archive_to_s3("REPORT", "DIFF", "PR 1", datetime.now(timezone.utc), "run123")
    assert "may still be" in out                        # honest that the diff may remain


def test_clean_sanitizes_pipes_and_newlines():
    assert review._clean("a|b\nc") == "a/b c"
    assert review._clean("x" * 300).endswith("…")


def test_truncated_synthesis_is_degraded_not_complete(monkeypatch, tmp_path, capsys):
    behaviour = {mid: _resp() for mid in review.REVIEWERS.values()}
    behaviour[review.SYNTHESIZER_ID] = _resp(text="partial", stop="max_tokens")
    code, _ = _run_main(monkeypatch, tmp_path, FakeBedrock(behaviour))
    out = capsys.readouterr().out
    assert code == 0
    assert "— DEGRADED" in out and "— COMPLETE" not in out   # header/warning agree
    assert "synthesis was truncated" in out
