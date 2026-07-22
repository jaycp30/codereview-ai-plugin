#!/usr/bin/env bash
#
# Interactive installer / configurator for the multi-model PR code-review plugin.
#
# What it does, all against the AWS account your terminal is currently logged
# into (nothing is hardcoded):
#   1. Detects your active AWS identity and region.
#   2. Lets you choose the three reviewer models + the synthesizer from Bedrock.
#   3. Optionally creates the S3 log bucket  codereview-logs-<random>  (90-day
#      lifecycle, public access blocked), or uses an existing one, or skips it.
#   4. Generates a least-privilege IAM policy scoped to just those models + bucket
#      and offers to create/attach it (you confirm every IAM change).
#   5. Writes ~/.codereview/config.json, which review.py reads at runtime.
#
# It never stores credentials — only account ID, region, bucket name, and model
# IDs. Safe to re-run: existing values are offered back as defaults, and the
# config file is only overwritten after you confirm.

set -euo pipefail

# --- constants --------------------------------------------------------------

CONFIG_DIR="${HOME}/.codereview"
CONFIG_FILE="${CONFIG_DIR}/config.json"
POLICY_FILE="${CONFIG_DIR}/codereview-policy.json"
POLICY_NAME="codereview-plugin"

# Defaults match review.py's DEFAULT_REVIEWERS / DEFAULT_SYNTHESIZER. Anthropic
# models use the "us." cross-region inference-profile prefix; Qwen/DeepSeek use
# bare IDs. Availability varies by account and region — verify yours.
DEFAULT_REVIEWER_1="us.anthropic.claude-sonnet-5"
DEFAULT_REVIEWER_2="qwen.qwen3-coder-next"
DEFAULT_REVIEWER_3="deepseek.v3.2"
DEFAULT_SYNTHESIZER="us.anthropic.claude-opus-4-8"

# --- small helpers ----------------------------------------------------------

# Print a section heading.
section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# ask VAR "prompt" "default" — read a value, falling back to the default on empty.
ask() {
    local __var="$1" __prompt="$2" __default="${3:-}" __reply=""
    if [[ -n "$__default" ]]; then
        read -r -p "${__prompt} [${__default}]: " __reply || true
        printf -v "$__var" '%s' "${__reply:-$__default}"
    else
        read -r -p "${__prompt}: " __reply || true
        printf -v "$__var" '%s' "$__reply"
    fi
}

# confirm "question" — returns 0 for yes, 1 for no (default no).
confirm() {
    local __reply=""
    read -r -p "$1 [y/N]: " __reply || true
    [[ "$__reply" =~ ^[Yy] ]]
}

# aws wrapper that injects --profile only when one is configured.
awscli() {
    if [[ -n "${PROFILE:-}" ]]; then
        aws --profile "$PROFILE" "$@"
    else
        aws "$@"
    fi
}

# --- preflight --------------------------------------------------------------

section "Preflight"
command -v aws >/dev/null 2>&1 || { echo "error: aws CLI not found. Install it first." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found. Install it first." >&2; exit 1; }
if ! python3 -c "import boto3" >/dev/null 2>&1; then
    echo "note: boto3 is not importable by this python3 — review.py needs it at runtime."
    echo "      install later with:  python3 -m pip install boto3"
fi
mkdir -p "$CONFIG_DIR"
echo "ok: aws + python3 present."

# --- AWS profile + identity -------------------------------------------------

section "AWS account"
echo "Leave the profile blank to use your default credential chain (the account"
echo "your terminal is already logged into)."
ask PROFILE "Named AWS profile to use (optional)" ""

if ! IDENT_JSON="$(awscli sts get-caller-identity --output json 2>/dev/null)"; then
    echo "error: could not verify AWS credentials." >&2
    echo "       Log in first (aws configure / SSO) and re-run setup.sh." >&2
    exit 1
fi
ACCOUNT="$(printf '%s' "$IDENT_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Account"])')"
ARN="$(printf '%s' "$IDENT_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Arn"])')"
echo "ok: authenticated as ${ARN}"
echo "    account: ${ACCOUNT}"

# --- region -----------------------------------------------------------------

section "Region"
DETECTED_REGION="$(awscli configure get region 2>/dev/null || true)"
DETECTED_REGION="${DETECTED_REGION:-${AWS_REGION:-us-east-1}}"
ask REGION "Region for Bedrock + S3" "$DETECTED_REGION"
if [[ "$REGION" != us-* ]]; then
    echo "warning: the default Anthropic model IDs use the 'us.' inference profile,"
    echo "         which only routes in US regions. In ${REGION} you'll likely need"
    echo "         different model IDs — set them in the next step."
fi

# --- models -----------------------------------------------------------------

section "Bedrock models"
echo "Three reviewers run in parallel; a fourth model synthesizes their findings."
echo "List what your account can call with:"
echo "    aws bedrock list-inference-profiles --region ${REGION}"
echo "    aws bedrock list-foundation-models  --region ${REGION}"
echo
ask REVIEWER_1 "Reviewer 1 model ID" "$DEFAULT_REVIEWER_1"
ask REVIEWER_2 "Reviewer 2 model ID" "$DEFAULT_REVIEWER_2"
ask REVIEWER_3 "Reviewer 3 model ID" "$DEFAULT_REVIEWER_3"
ask SYNTHESIZER "Synthesizer model ID" "$DEFAULT_SYNTHESIZER"

# --- S3 bucket --------------------------------------------------------------

section "S3 archive bucket"
echo "Every review (plus its input diff) is archived to S3 and expires after 90 days."
echo "  1) create a new bucket  codereview-logs-<random>  (recommended)"
echo "  2) use an existing bucket"
echo "  3) skip archiving"
ask BUCKET_CHOICE "Choose 1/2/3" "1"

BUCKET=""
case "$BUCKET_CHOICE" in
    1)
        SUFFIX="$(python3 -c 'import secrets;print(secrets.token_hex(4))')"
        BUCKET="codereview-logs-${SUFFIX}"
        echo "Will create: s3://${BUCKET} in ${REGION}"
        if confirm "Create this bucket now? (creates a billable S3 bucket)"; then
            # us-east-1 rejects a LocationConstraint; every other region requires one.
            if [[ "$REGION" == "us-east-1" ]]; then
                awscli s3api create-bucket --bucket "$BUCKET" --region "$REGION"
            else
                awscli s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
                    --create-bucket-configuration "LocationConstraint=${REGION}"
            fi
            # Block all public access — review archives are private by nature.
            awscli s3api put-public-access-block --bucket "$BUCKET" \
                --public-access-block-configuration \
                "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
            # 90-day expiry on the reviews/ prefix keeps storage bounded.
            awscli s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
                --lifecycle-configuration '{"Rules":[{"ID":"expire-reviews","Status":"Enabled","Filter":{"Prefix":"reviews/"},"Expiration":{"Days":90}}]}'
            echo "ok: created and configured s3://${BUCKET}"
        else
            echo "skipped bucket creation; recording the name in config so you can create it later."
        fi
        ;;
    2)
        ask BUCKET "Existing bucket name" ""
        ;;
    *)
        echo "skipping archiving; reviews will only print to the terminal."
        ;;
esac

# --- IAM policy -------------------------------------------------------------

section "IAM policy (least privilege)"
# Generate a policy scoped to exactly the chosen models + bucket. Region is
# wildcarded on the foundation-model ARNs because cross-region inference profiles
# route the call across several regions; the profile ARN stays account-scoped.
ALL_MODELS="${REVIEWER_1} ${REVIEWER_2} ${REVIEWER_3} ${SYNTHESIZER}"
ACCOUNT="$ACCOUNT" BUCKET="$BUCKET" MODELS="$ALL_MODELS" python3 - "$POLICY_FILE" <<'PY'
import json, os, sys

account = os.environ["ACCOUNT"]
bucket = os.environ.get("BUCKET", "")
models = os.environ["MODELS"].split()

# Geographic inference-profile prefixes: the system-defined cross-region and
# global profiles that fan a call out across regions. An ID that starts with one
# of these is a profile (needs both the profile ARN and the underlying model
# ARN); anything else is a bare on-demand foundation model. If AWS adds new
# country-level profiles, this is the one set to extend.
GEO_PREFIXES = {"us", "us-gov", "eu", "apac", "jp", "au", "global"}

foundation, profiles = set(), set()
for m in models:
    head = m.split(".", 1)[0]
    if head in GEO_PREFIXES and "." in m:
        profiles.add(f"arn:aws:bedrock:*:{account}:inference-profile/{m}")
        foundation.add(f"arn:aws:bedrock:*::foundation-model/{m.split('.', 1)[1]}")
    else:
        foundation.add(f"arn:aws:bedrock:*::foundation-model/{m}")

statements = [{
    "Sid": "InvokeReviewModels",
    "Effect": "Allow",
    "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
    "Resource": sorted(foundation) + sorted(profiles),
}]
if bucket:
    statements.append({
        "Sid": "ArchiveReviews", "Effect": "Allow",
        "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
        "Resource": [f"arn:aws:s3:::{bucket}/*"],
    })
    statements.append({
        "Sid": "ListArchiveBucket", "Effect": "Allow",
        "Action": ["s3:ListBucket"],
        "Resource": [f"arn:aws:s3:::{bucket}"],
    })

policy = {"Version": "2012-10-17", "Statement": statements}
with open(sys.argv[1], "w") as fh:
    json.dump(policy, fh, indent=2)
    fh.write("\n")
PY
echo "ok: wrote policy to ${POLICY_FILE}"
echo "    (grants only InvokeModel on your chosen models + read/write on the bucket)"

if confirm "Create this as a managed IAM policy '${POLICY_NAME}' now?"; then
    if POLICY_ARN="$(awscli iam create-policy --policy-name "$POLICY_NAME" \
            --policy-document "file://${POLICY_FILE}" \
            --query 'Policy.Arn' --output text 2>/dev/null)"; then
        echo "ok: created ${POLICY_ARN}"
        # Attaching to a user only makes sense for IAM-user identities.
        IAM_USER="$(printf '%s' "$ARN" | sed -n 's#.*:user/\(.*\)#\1#p')"
        if [[ -n "$IAM_USER" ]] && confirm "Attach it to IAM user '${IAM_USER}'?"; then
            awscli iam attach-user-policy --user-name "$IAM_USER" --policy-arn "$POLICY_ARN"
            echo "ok: attached ${POLICY_NAME} to ${IAM_USER}"
        else
            echo "not attached. Attach it to your user/role manually when ready:"
            echo "    aws iam attach-user-policy --user-name <you> --policy-arn ${POLICY_ARN}"
        fi
    else
        echo "note: could not create the policy (it may already exist, or you lack"
        echo "      iam:CreatePolicy). The JSON is saved at ${POLICY_FILE} — apply it"
        echo "      yourself or ask an admin to."
    fi
else
    echo "skipped. Apply ${POLICY_FILE} yourself when ready."
fi

# --- optional account lock --------------------------------------------------

section "Account guard (optional)"
echo "You can pin reviews to this account only, so the tool fails closed if your"
echo "credentials ever point somewhere else (useful with multiple AWS accounts)."
LOCK_ACCOUNT=""
if confirm "Lock reviews to account ${ACCOUNT}?"; then
    LOCK_ACCOUNT="$ACCOUNT"
fi

# --- write config.json ------------------------------------------------------

section "Writing config"
PROFILE="$PROFILE" REGION="$REGION" LOCK_ACCOUNT="$LOCK_ACCOUNT" BUCKET="$BUCKET" \
REVIEWER_1="$REVIEWER_1" REVIEWER_2="$REVIEWER_2" REVIEWER_3="$REVIEWER_3" \
SYNTHESIZER="$SYNTHESIZER" \
python3 - "$CONFIG_FILE" <<'PY'
import json, os, re, sys

# Friendly labels for the shipped defaults; anything custom gets a name derived
# from its model ID (region-route prefix stripped) so the status table stays readable.
KNOWN = {
    "us.anthropic.claude-sonnet-5": "claude-sonnet-5",
    "qwen.qwen3-coder-next": "qwen3-coder-next",
    "deepseek.v3.2": "deepseek-v3.2",
}

def label(model_id):
    if model_id in KNOWN:
        return KNOWN[model_id]
    # Strip a leading geographic inference-profile prefix so the status-table
    # name reads as the model, not the routing region (kept in sync with the
    # policy generator's GEO_PREFIXES).
    name = re.sub(r"^(us-gov|global|apac|eu|au|jp|us)\.", "", model_id)
    return name.replace(".", "-")

reviewers = {}
for mid in (os.environ["REVIEWER_1"], os.environ["REVIEWER_2"], os.environ["REVIEWER_3"]):
    key, n = label(mid), 2
    base = key
    while key in reviewers:          # guarantee unique keys if two IDs collapse
        key = f"{base}-{n}"; n += 1
    reviewers[key] = mid

config = {"reviewers": reviewers, "synthesizer": os.environ["SYNTHESIZER"]}
# Only record optional settings when set, so unset ones fall back to AWS defaults.
if os.environ.get("PROFILE"):      config["profile"] = os.environ["PROFILE"]
if os.environ.get("REGION"):       config["region"] = os.environ["REGION"]
if os.environ.get("BUCKET"):       config["s3_bucket"] = os.environ["BUCKET"]
if os.environ.get("LOCK_ACCOUNT"): config["account_id"] = os.environ["LOCK_ACCOUNT"]

with open(sys.argv[1], "w") as fh:
    json.dump(config, fh, indent=2)
    fh.write("\n")
PY
echo "ok: wrote ${CONFIG_FILE}"

# --- summary ----------------------------------------------------------------

section "Done"
echo "Configuration:"
python3 -m json.tool "$CONFIG_FILE"
echo
echo "Try a review from any git repo:"
echo "    /pr:codereview 123        (inside Claude Code, after installing the plugin)"
echo "  or standalone:"
echo "    git diff origin/main...HEAD > changes.diff"
echo "    python3 plugins/pr/review.py --diff changes.diff --label 'PR 123'"
if [[ -n "${PROFILE:-}" ]]; then
    echo
    echo "You chose profile '${PROFILE}'. Claude Code runs a NON-interactive shell that"
    echo "sources ~/.zshenv (not ~/.zshrc), and it does not read this config's profile"
    echo "field unless review.py picks it up — it does. No extra env var is required,"
    echo "but if you also want the profile visible to ad-hoc shells, add it to ~/.zshenv:"
    echo "    echo 'export CODEREVIEW_AWS_PROFILE=${PROFILE}' >> ~/.zshenv"
fi
