"""Usage-limit detection and waiting for a stage whose ``claude -p`` died on the account limit.

The account's rolling limit (session / usage / weekly) kills a stage with rc=1 and no
spend: the CLI prints a synthetic assistant message ("You've hit your session limit ·
resets 7pm (Europe/Kiev)") and a ``result`` event carrying ``api_error_status`` 429.
That is a property of the account, not of the stage, so the stage is re-dispatched after
the reset instead of failing the run. Nothing here dispatches: detection is pure and the
policy sleeps through an injected ``sleep``.
"""

from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from datetime import datetime, time as dtime, timedelta, timezone, tzinfo
from typing import Callable, Iterator, Optional
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

# A cap on one wait and on the run's cumulative waiting, so a misparsed reset can never
# park a run indefinitely.
DEFAULT_CAP_S = 6 * 3600
# Past the stated reset: the account's clock and ours are not the same clock.
DEFAULT_MARGIN_S = 120
# Re-probe interval when the message carries no reset time. A re-dispatch into a still
# active limit is rejected before it does any work, so polling costs nothing.
DEFAULT_POLL_S = 15 * 60

_LIMIT_RE = re.compile(r"hit your (?:session|usage|weekly) limit", re.IGNORECASE)
_RESETS_RE = re.compile(
    r"resets\s+(?:at\s+)?"
    r"(?:(?P<mon>[A-Za-z]{3,9})\.?\s+(?P<day>\d{1,2})(?:st|nd|rd|th)?,?\s+(?:at\s+)?)?"
    r"(?P<h>\d{1,2})(?::(?P<min>\d{2}))?\s*(?P<ap>[ap]\.?m\.?)?"
    r"(?:\s*\((?P<tz>[^)]+)\))?",
    re.IGNORECASE)
# "resets <time>" alone is ordinary prose; it only counts as the limit banner when the
# text is this short, because the banner is one line.
_BANNER_MAX_CHARS = 200
_MONTHS = {m: i for i, m in enumerate(
    ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"), 1)}


@dataclass(frozen=True)
class UsageLimit:
    message: str
    reset_at: Optional[datetime] = None   # aware, UTC; None when the CLI gave no parsable time
    reset_text: Optional[str] = None      # the ``resets ...`` phrase as printed


class UsageLimitHit(Exception):
    """A stage could not run because of the usage limit and waiting was not possible."""

    def __init__(self, limit: UsageLimit, reason: str) -> None:
        super().__init__(reason)
        self.limit = limit
        self.reason = reason


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _zone(name: Optional[str], now: datetime) -> tzinfo:
    if name:
        try:
            return ZoneInfo(name.strip())
        except (ZoneInfoNotFoundError, ValueError, OSError):
            pass
    # An unknown or absent zone falls back to this machine's: the CLI prints the
    # operator's own local time.
    return now.astimezone().tzinfo or timezone.utc


def parse_reset(text: str, now: datetime) -> Optional[datetime]:
    """The next instant ``resets <time>`` names, as aware UTC; None when there is none.

    Accepts ``7pm``, ``7:30pm`` and ``19:00``, an optional ``(Area/City)`` zone, and an
    optional leading ``Oct 3``. A bare hour without am/pm or minutes is not a time.
    """
    m = _RESETS_RE.search(text)
    if m is None:
        return None
    meridiem = (m["ap"] or "").lower().replace(".", "")
    if not (meridiem or m["min"]):
        return None
    hour, minute = int(m["h"]), int(m["min"] or 0)
    if meridiem:
        if not 1 <= hour <= 12:
            return None
        hour = hour % 12 + (12 if meridiem == "pm" else 0)
    if hour > 23 or minute > 59:
        return None
    zone = _zone(m["tz"], now)
    local_now = now.astimezone(zone)
    at = dtime(hour, minute)
    try:
        if m["mon"]:
            month = _MONTHS.get(m["mon"][:3].lower())
            if month is None:
                return None
            day = datetime(local_now.year, month, int(m["day"]), tzinfo=zone).date()
            candidate = datetime.combine(day, at, tzinfo=zone)
            if candidate < local_now - timedelta(days=30):
                candidate = datetime.combine(day.replace(year=day.year + 1), at, tzinfo=zone)
        else:
            candidate = datetime.combine(local_now.date(), at, tzinfo=zone)
            if candidate <= local_now:
                candidate = datetime.combine(local_now.date() + timedelta(days=1), at,
                                             tzinfo=zone)
    except ValueError:
        return None
    return candidate.astimezone(timezone.utc)


def _events(stdout: str) -> Iterator[dict]:
    """Every JSON object in ``stdout``: stream-json lines, else one document."""
    seen = False
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except (ValueError, TypeError):
            continue
        if isinstance(event, dict):
            seen = True
            yield event
    if seen:
        return
    try:
        whole = json.loads(stdout)
    except (ValueError, TypeError):
        return
    for event in whole if isinstance(whole, list) else [whole]:
        if isinstance(event, dict):
            yield event


def _texts(event: dict) -> Iterator[str]:
    if event.get("type") == "result" and isinstance(event.get("result"), str):
        yield event["result"]
    message = event.get("message")
    if (event.get("type") == "assistant" and isinstance(message, dict)
            and isinstance(message.get("content"), list)):
        for block in message["content"]:
            if isinstance(block, dict) and isinstance(block.get("text"), str):
                yield block["text"]


def _rejected_reset(event: dict) -> Optional[datetime]:
    """``resetsAt`` (epoch s) from a quota block the CLI marked rejected, when present."""
    for node in (event, event.get("rate_limit_info"), event.get("quotaLimits")):
        if (isinstance(node, dict) and node.get("status") == "rejected"
                and isinstance(node.get("resetsAt"), (int, float))):
            try:
                return datetime.fromtimestamp(node["resetsAt"], timezone.utc)
            except (OverflowError, OSError, ValueError):
                return None
    return None


def detect(stdout: str, now: Optional[datetime] = None) -> Optional[UsageLimit]:
    """Classify a failed stage's full stdout as a usage limit, else None.

    Signals: a result/assistant text matching ``hit your (session|usage|weekly) limit``
    or a short ``resets <time>`` banner, or ``api_error_status`` 429 on any event. The
    reset comes from a rejected quota block's epoch when the stream carries one, else
    from the printed time.
    """
    now = now or _now_utc()
    message: Optional[str] = None
    epoch_reset: Optional[datetime] = None
    for event in _events(stdout):
        status = event.get("api_error_status", event.get("apiErrorStatus"))
        if status == 429 and message is None:
            message = "HTTP 429 from the API"
        epoch_reset = _rejected_reset(event) or epoch_reset
        for text in _texts(event):
            banner = len(text) <= _BANNER_MAX_CHARS and _RESETS_RE.search(text)
            if _LIMIT_RE.search(text) or (banner and parse_reset(text, now) is not None):
                message = text.strip()
    if message is None:
        return None
    m = _RESETS_RE.search(message)
    reset_text = m.group(0).strip() if m else None
    return UsageLimit(message=message, reset_text=reset_text,
                      reset_at=epoch_reset or parse_reset(message, now))


@dataclass
class LimitPolicy:
    """What to do when a stage hits the limit: sleep through it, or give up.

    ``waited_s`` is cumulative across the whole run, so the cap bounds total waiting,
    not each wait alone.
    """

    wait: bool = True
    cap_s: float = DEFAULT_CAP_S
    margin_s: float = DEFAULT_MARGIN_S
    poll_s: float = DEFAULT_POLL_S
    sleep: Callable[[float], None] = time.sleep
    now: Callable[[], datetime] = _now_utc
    log: Callable[[str], None] = lambda _line: None
    waited_s: float = field(default=0.0, init=False)

    def wait_out(self, limit: UsageLimit, where: str) -> None:
        """Return after sleeping past the reset; raise ``UsageLimitHit`` when it cannot."""
        if not self.wait:
            raise UsageLimitHit(limit, "waiting on the limit is disabled")
        if limit.reset_at is not None:
            seconds = max((limit.reset_at - self.now()).total_seconds(), 0.0) + self.margin_s
            until = f"reset {limit.reset_at.strftime('%Y-%m-%dT%H:%M:%SZ')}"
        else:
            seconds = self.poll_s
            until = "no reset time given, polling"
        if self.waited_s + seconds > self.cap_s:
            raise UsageLimitHit(
                limit, f"waiting {seconds / 3600:.1f}h would exceed the "
                       f"{self.cap_s / 3600:.0f}h cap ({self.waited_s / 3600:.1f}h already waited)")
        self.log(f"usage limit at {where}: {until}; sleeping {int(seconds)}s "
                 f"(margin {int(self.margin_s)}s), then re-dispatching {where}")
        self.sleep(seconds)
        self.waited_s += seconds


def describe(hit: UsageLimitHit) -> str:
    """One line naming the reset, for the operator and the partial-record warning."""
    limit = hit.limit
    when = (limit.reset_at.strftime("%Y-%m-%dT%H:%M:%SZ") if limit.reset_at is not None
            else limit.reset_text or "unknown")
    return f"{limit.message!r}; resets at {when} ({hit.reason})"
