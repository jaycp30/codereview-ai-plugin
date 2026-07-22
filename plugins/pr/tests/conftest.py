"""Test isolation: pin the engine's config resolution to a hermetic state
BEFORE review.py is imported, so a developer's real ~/.codereview/config.json or
stray CODEREVIEW_* env vars can never change what the tests see. conftest.py is
imported before the test modules, which is exactly when review.py reads config.
"""

import os

# Point at a path that cannot exist, so _load_config_file() returns {} and the
# built-in defaults apply deterministically.
os.environ["CODEREVIEW_CONFIG"] = os.path.join(os.sep, "nonexistent", "codereview-test-config.json")

# Drop any real deployment settings from the environment so nothing leaks in.
for _var in (
    "CODEREVIEW_AWS_PROFILE",
    "CODEREVIEW_AWS_REGION",
    "CODEREVIEW_AWS_ACCOUNT_ID",
    "CODEREVIEW_S3_BUCKET",
    "CODEREVIEW_SYNTHESIZER",
):
    os.environ.pop(_var, None)
