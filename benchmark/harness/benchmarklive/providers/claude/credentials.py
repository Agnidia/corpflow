"""Fail-fast credential probe.

Live mode requires an Anthropic credential before ANY stage is dispatched. Two
sources: ANTHROPIC_API_KEY (checked FIRST — cheap short-circuit) OR an active
`claude` CLI login. Neither the key value nor any CLI-login identity is EVER
printed, logged, echoed into argv, or written to a record — only boolean presence.
rc=3 semantics live in dispatch.dispatch.
"""

from __future__ import annotations

import json
import os
from typing import Callable, Optional

from benchmarkkit.genlib import Subprocess

from ... import isolation

CREDENTIAL_ENV = "ANTHROPIC_API_KEY"

# Frozen error message (byte-exact contract; ported tests assert equality).
MISSING_CREDENTIAL_MESSAGE = (
    "live mode requires credentials; set ANTHROPIC_API_KEY or run claude login"
)


class CredentialError(Exception):
    def __init__(self) -> None:
        super().__init__(MISSING_CREDENTIAL_MESSAGE)


def default_auth_status_runner(config_dir: Optional[str] = None) -> str:
    """Production runner: `claude auth status --json`, read-only, no spend.

    ``config_dir`` pins ``CLAUDE_CONFIG_DIR``: the stages run against that dir, so a
    login in the operator's default config says nothing about whether they can run.
    """
    env = isolation.claude_env(config_dir) if config_dir else None
    return Subprocess.run(["claude", "auth", "status", "--json"], env=env).stdout


def has_cli_login(runner: Optional[Callable[[], str]] = None,
                  config_dir: Optional[str] = None) -> bool:
    """True iff `claude auth status --json` reports loggedIn: true. Defensive → False.

    Only the boolean is ever returned — email/orgId/authMethod never surface.
    """
    run = runner or (lambda: default_auth_status_runner(config_dir))
    try:
        stdout = run()
    except Exception:
        return False
    try:
        parsed = json.loads(stdout)
    except (ValueError, TypeError):
        return False
    return isinstance(parsed, dict) and parsed.get("loggedIn") is True


def has_credential(env: Optional[dict] = None,
                   cli_login_runner: Optional[Callable[[], str]] = None,
                   config_dir: Optional[str] = None) -> bool:
    """True iff a usable credential exists via either source. Env key short-circuits."""
    source = env if env is not None else os.environ
    value = source.get(CREDENTIAL_ENV)
    if value is not None and value.strip():
        return True
    return has_cli_login(runner=cli_login_runner, config_dir=config_dir)


def require_credential(env: Optional[dict] = None,
                       cli_login_runner: Optional[Callable[[], str]] = None,
                       config_dir: Optional[str] = None) -> None:
    """Raise CredentialError (frozen message) when no credential exists."""
    if not has_credential(env=env, cli_login_runner=cli_login_runner, config_dir=config_dir):
        raise CredentialError()
