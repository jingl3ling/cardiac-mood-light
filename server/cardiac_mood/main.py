"""
Cardiac Mood Light API — BPM window → Claude (optional) → mood + LED state.
"""

from __future__ import annotations

import json
import logging
import math
import os
import time
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, field_validator

from cardiac_mood.classifier import classify_heuristic

load_dotenv()

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("cardiac_mood")

app = FastAPI(title="Cardiac Mood Light", version="1.0.0")

API_KEY = os.environ.get("API_KEY", "").strip()
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "").strip()
# Default to Haiku for classify + explain-mood cost; override with CLAUDE_MODEL for Sonnet etc.
CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL", "claude-3-5-haiku-20241022")

MOODS = frozenset({"calm", "stressed", "happy", "sad"})

# Default LED brightness (0–255) for mood/analyze until the user sets it from the app slider (`/manual`).
DEFAULT_LAMP_BRIGHTNESS = 120

# Fixed palette — server assigns; Claude only picks mood id.
STYLE: dict[str, dict[str, Any]] = {
    "calm": {"label": "Calm (baseline)", "color": "#FFD700", "brightness": DEFAULT_LAMP_BRIGHTNESS},
    "stressed": {"label": "Escalating / Stressed", "color": "#FF0000", "brightness": DEFAULT_LAMP_BRIGHTNESS},
    "happy": {"label": "Happy / Energetic", "color": "#FF69B4", "brightness": DEFAULT_LAMP_BRIGHTNESS},
    "sad": {"label": "Sad / Drained", "color": "#4169E1", "brightness": DEFAULT_LAMP_BRIGHTNESS},
}

# deviceId -> latest state
_STORE: dict[str, dict[str, Any]] = {}


class HRSample(BaseModel):
    t: str = Field(..., description="ISO8601 timestamp")
    bpm: float = Field(..., ge=30, le=230)


class AnalyzeBody(BaseModel):
    deviceId: str = Field(..., min_length=1, max_length=128)
    restingBpm: float | None = Field(None, ge=30, le=120)
    samples: list[HRSample] = Field(..., min_length=1, max_length=64)
    timeZoneId: str | None = Field(
        None,
        max_length=128,
        description="IANA time zone (e.g. America/New_York) for local time context in mood rules",
    )

    @field_validator("samples")
    @classmethod
    def sort_by_time(cls, v: list[HRSample]) -> list[HRSample]:
        return sorted(v, key=lambda s: s.t)


class ManualLampBody(BaseModel):
    """Set lamp color/brightness from the phone; same store as /analyze for ESP32 polling."""

    deviceId: str = Field(..., min_length=1, max_length=128)
    mood: str = Field(..., description="One of calm|stressed|happy|sad (drives label; color from palette unless overridden)")
    brightness: int = Field(..., ge=0, le=255)
    color: str | None = Field(
        None,
        description="Optional #RRGGBB; if set, overrides palette color for the device",
    )
    powerOn: bool = Field(True, description="When false, ESP32 keeps LEDs off")
    blinkEnabled: bool = Field(False, description="Pulse LEDs to blinkBpm when true")
    blinkBpm: float = Field(72.0, ge=30.0, le=220.0, description="Target BPM for blink rhythm")
    moodLabel: str | None = Field(
        None,
        max_length=48,
        description="Optional display name for this mood (shown instead of preset label when set)",
    )

    @field_validator("mood")
    @classmethod
    def mood_ok(cls, v: str) -> str:
        m = v.lower().strip()
        if m not in MOODS:
            raise ValueError("mood must be one of calm, stressed, happy, sad")
        return m

    @field_validator("color")
    @classmethod
    def color_ok(cls, v: str | None) -> str | None:
        if v is None or v == "":
            return None
        s = v.strip()
        if not s.startswith("#") or len(s) != 7:
            raise ValueError("color must be #RRGGBB")
        for ch in s[1:]:
            if ch not in "0123456789abcdefABCDEF":
                raise ValueError("color must be #RRGGBB")
        return s

    @field_validator("moodLabel")
    @classmethod
    def mood_label_strip(cls, v: str | None) -> str | None:
        if v is None:
            return None
        s = v.strip()
        return s if s else None


def require_api_key(x_api_key: str | None) -> None:
    if not API_KEY:
        return
    if (x_api_key or "").strip() != API_KEY:
        raise HTTPException(status_code=401, detail="unauthorized")


def _now_in_user_tz(time_zone_id: str) -> dict[str, str]:
    """Authoritative local clock in the user's zone (server-computed; avoids client date drift)."""
    tz_id = (time_zone_id or "").strip() or "UTC"
    try:
        tz = ZoneInfo(tz_id)
    except Exception:
        tz = ZoneInfo("UTC")
        tz_id = "UTC"
    n = datetime.now(tz)
    wd = n.strftime("%a")
    date_iso = n.strftime("%Y-%m-%d")
    hm = n.strftime("%H:%M")
    hour = n.hour
    if 5 <= hour < 12:
        period = "morning"
    elif 12 <= hour < 17:
        period = "afternoon"
    elif 17 <= hour < 22:
        period = "evening"
    else:
        period = "night"
    # Single compact line Claude must treat as ground truth for weekday + time-of-day
    one = f"{wd} {date_iso} {hm} {tz_id} {period}"
    return {"date_iso": date_iso, "one_liner": one, "period": period}


# Tokens kept small: short rules + low max_tokens on the API call.
CLAUDE_SYSTEM = """JSON only, no markdown: {"mood":"calm|stressed|happy|sad","reason":"<≤12 words>"}
Often ONE current BPM vs resting_bpm (Apple Health). Use delta vs resting first — not stereotypes alone.
If multiple bpms (oldest→newest), a workout window can show swings or a climb — reflect that briefly.
calm≈near resting; stressed=high vs resting or erratic multi-sample swings; happy=clear lift; sad=low vs resting.
Optional local_one_line is user's clock — flavor only; no medical claims."""


async def classify_claude(
    resting_bpm: float | None,
    bpms: list[float],
    time_zone_id: str | None,
) -> tuple[str, str]:
    b = bpms[-16:] if len(bpms) > 16 else bpms
    payload: dict[str, Any] = {"resting_bpm": resting_bpm, "bpms": b, "n": len(b)}
    tz = (time_zone_id or "").strip()
    if tz:
        payload["local_one_line"] = _now_in_user_tz(tz)["one_liner"]
    user_text = json.dumps(payload, separators=(",", ":"))

    body = {
        "model": CLAUDE_MODEL,
        "max_tokens": 128,
        "system": CLAUDE_SYSTEM,
        "messages": [{"role": "user", "content": user_text}],
    }

    async with httpx.AsyncClient(timeout=30.0) as client:
        r = await client.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": ANTHROPIC_API_KEY,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json=body,
        )
        r.raise_for_status()
        data = r.json()

    texts: list[str] = []
    for block in data.get("content") or []:
        if isinstance(block, dict) and block.get("type") == "text":
            texts.append(block.get("text") or "")
    raw = "".join(texts).strip()
    # Model may wrap JSON in markdown fences
    if "```" in raw:
        start = raw.find("{")
        end = raw.rfind("}")
        if start >= 0 and end > start:
            raw = raw[start : end + 1]

    parsed = json.loads(raw)
    mood = str(parsed.get("mood", "")).lower().strip()
    reason = str(parsed.get("reason", "")).strip() or "claude"
    if mood not in MOODS:
        raise ValueError(f"invalid mood: {mood}")
    return mood, reason


def _prev_extras(device_id: str) -> tuple[bool, bool, float]:
    prev = _STORE.get(device_id) or {}
    power_on = bool(prev.get("powerOn", True))
    blink_en = bool(prev.get("blinkEnabled", False))
    try:
        bpm = float(prev.get("blinkBpm", 72.0))
    except (TypeError, ValueError):
        bpm = 72.0
    bpm = max(30.0, min(220.0, bpm))
    return power_on, blink_en, bpm


def pack_state(device_id: str, mood: str, reason: str, source: str) -> dict[str, Any]:
    """Analyze path: keep lamp power + blink settings from last manual/device state."""
    st = STYLE[mood]
    power_on, blink_en, bpm = _prev_extras(device_id)
    state = {
        "deviceId": device_id,
        "mood": mood,
        "label": st["label"],
        "color": st["color"],
        "brightness": int(st["brightness"]),
        "reason": reason,
        "source": source,
        "updatedAt": time.time(),
        "powerOn": power_on,
        "blinkEnabled": blink_en,
        "blinkBpm": bpm,
    }
    _STORE[device_id] = state
    return state


EXPLAIN_MOOD_SYSTEM = """JSON only: {"caption":"<one sentence ≤200 chars>"}
Keys: m=base mood (calm|stressed|happy|sad, lamp palette only); n=authoritative local now—use n only for weekday/time; never contradict n.
h=null or {r,b,c,s} HR compact. No diagnoses.
u=optional user mood name (their word). uf=1 means u reads like a real feeling/word; uf=0 means u looks like random typing—do NOT invent causes (no people/weather/news filler); write one warm sentence that their feeling is valid without guessing why, e.g. that it's okay not to name it perfectly.
If uf=1 and u set: caption MUST match u's emotion—e.g. scared/fearful→tension, surprises, darkness, worry; peaceful→quiet wind-down; joyful→bright moments. Never give calm/peaceful evening copy when u implies fear or panic. If u empty: tone follows m and n.
Blend HR (h) with n when present; keep one sentence. Plain text, no markdown."""


def pack_manual(
    device_id: str,
    mood: str,
    brightness: int,
    color_override: str | None,
    *,
    power_on: bool,
    blink_enabled: bool,
    blink_bpm: float,
    custom_label: str | None,
) -> dict[str, Any]:
    st = STYLE[mood]
    color = color_override if color_override else st["color"]
    label = custom_label if custom_label else st["label"]
    bpm = max(30.0, min(220.0, float(blink_bpm)))
    state = {
        "deviceId": device_id,
        "mood": mood,
        "label": label,
        "color": color,
        "brightness": int(brightness),
        "reason": "manual_ios",
        "source": "manual",
        "updatedAt": time.time(),
        "powerOn": power_on,
        "blinkEnabled": blink_enabled,
        "blinkBpm": bpm,
    }
    _STORE[device_id] = state
    return state


def _everyday_context_fragment(local_date: str, mood: str) -> str:
    """Short non-HR flavor: weekday, season, mood tone — used alone or paired with pulse hints."""
    try:
        import datetime as dt

        d = dt.date.fromisoformat(local_date)
        wd = d.weekday()
        month = d.month
    except ValueError:
        wd = 0
        month = 5

    vibe: list[str] = []
    if wd >= 5:
        vibe.append("weekend softness")
    elif wd == 0:
        vibe.append("fresh-week energy")
    else:
        vibe.append("midweek rhythms")

    if month in (11, 12):
        vibe.append("holiday-season glow")
    elif month in (6, 7, 8):
        vibe.append("summery brightness peeking in")
    elif month in (12, 1, 2):
        vibe.append("cozy winter-light indoors")

    mood_line = {
        "calm": "Calm fits quiet corners",
        "stressed": "Stressed hues nod to a wired moment",
        "happy": "Happy sparkles match upbeat vibes",
        "sad": "Soft blues honor a low-energy spell",
    }.get(mood, "This mood fits the moment")

    extra = ", ".join(vibe[:2])
    return f"{mood_line} — maybe {extra}, or whatever your day's weather feels like"


def _label_likely_gibberish(label: str) -> bool:
    """Heuristic: keyboard mash / random letters—not for judging real rare words."""
    raw = label.strip()
    if not raw:
        return False
    letters = "".join(ch for ch in raw if ch.isalpha())
    if len(letters) < 2:
        return True
    low = letters.lower()
    if len(low) >= 2 and len(set(low)) == 1:
        return True
    vowels = sum(1 for c in low if c in "aeiouy")
    if len(low) >= 4 and vowels == 0:
        return True
    if len(low) >= 5 and (vowels / len(low)) < 0.12:
        return True
    alpha_chars = [c for c in raw if c.isalpha()]
    if len(alpha_chars) >= 5:
        up = [c.isupper() for c in alpha_chars]
        transitions = sum(1 for i in range(len(up) - 1) if up[i] != up[i + 1])
        if transitions >= max(3, int(len(up) * 0.4)):
            return True
    return False


def _gibberish_custom_label_caption() -> str:
    return "I'm sure you feel this way for a certain reason—no need to put it into perfect words."


def _fallback_emotional_hint_for_custom_label(label: str, mood: str) -> str:
    """Tiny heuristic line so offline copy still tracks the user's word."""
    low = label.lower()
    m = mood.lower().strip()
    if any(x in low for x in ("scar", "fear", "afraid", "panic", "terror", "fright")):
        return "Shadows, sudden noise, or a racing mind can stir that feeling—let the light stay gentle."
    if any(x in low for x in ("angry", "rage", "mad", "furious")):
        return "Heat-of-the-moment friction or unfair surprises often fuel that spark—breathe with the glow."
    if any(x in low for x in ("sad", "blue", "down", "grief", "lonely")):
        return "Quiet rooms, long evenings, or missing someone can land heavy—soft light helps hold the space."
    if any(x in low for x in ("happy", "joy", "excited", "thrilled")):
        return "Good news, friends, or a burst of energy might paint the night—ride the brightness."
    if any(x in low for x in ("calm", "peace", "relaxed", "chill", "zen")):
        return "Slow breathing, a cozy corner, or wind-down time fits this hue."
    if any(x in low for x in ("stress", "worried", "anxious", "tense")):
        return "Deadlines, pings, or what-ifs can wind you tight—small rituals and dim warmth help."
    tail = {
        "calm": "needing less noise, a slower breath, or a softer corner",
        "stressed": "overload, deadlines, or a nervous system on high alert",
        "happy": "good news, bright company, or plain relief today",
        "sad": "a heavy hour, goodbyes, or quiet tiredness",
    }.get(m, "what you're carrying today")
    return f"If «{label}» fits you, this {m} light can echo {tail}—take what resonates."


def _fallback_explain_caption(
    mood: str,
    *,
    has_hr: bool,
    classifier_reason: str | None,
    recent_bpms: list[float] | None,
    local_date: str,
    custom_mood_name: str | None = None,
) -> str:
    """Deterministic copy when Claude is unavailable; blends HR hints with everyday context when both apply."""
    cr = (classifier_reason or "").strip()
    junk = {"", "manual_ios", "claude", "too few samples"}
    everyday = _everyday_context_fragment(local_date, mood)
    cu = (custom_mood_name or "").strip()[:48]

    hr_part: str | None = None
    if has_hr and recent_bpms:
        avg = sum(recent_bpms) / len(recent_bpms)
        if cr and cr not in junk:
            hr_part = f"Your recent pulse looked {cr}, with beats near {avg:.0f} BPM"
        else:
            hr_part = f"Recent heart-rate samples hovered near {avg:.0f} BPM"
    elif has_hr and cr and cr not in junk:
        hr_part = f"Your pulse pattern looked {cr}"

    if cu:
        if _label_likely_gibberish(cu):
            gib = _gibberish_custom_label_caption()
            if hr_part:
                return f"{hr_part} — {gib}"
            return gib
        label_hint = _fallback_emotional_hint_for_custom_label(cu, mood)
        mid = f"For «{cu}»: {label_hint}"
        if hr_part:
            return f"{hr_part} — {mid} — {everyday}"
        return f"{mid} — {everyday}."

    if hr_part:
        return f"{hr_part} — {everyday}."
    return f"{everyday}."


async def explain_mood_caption_claude(payload_user: dict[str, Any]) -> str:
    body = {
        "model": CLAUDE_MODEL,
        "max_tokens": 120,
        "system": EXPLAIN_MOOD_SYSTEM,
        "messages": [{"role": "user", "content": json.dumps(payload_user, separators=(",", ":"))}],
    }

    async with httpx.AsyncClient(timeout=30.0) as client:
        r = await client.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": ANTHROPIC_API_KEY,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json=body,
        )
        r.raise_for_status()
        data = r.json()

    texts: list[str] = []
    for block in data.get("content") or []:
        if isinstance(block, dict) and block.get("type") == "text":
            texts.append(block.get("text") or "")
    raw = "".join(texts).strip()
    if "```" in raw:
        start = raw.find("{")
        end = raw.rfind("}")
        if start >= 0 and end > start:
            raw = raw[start : end + 1]

    parsed = json.loads(raw)
    cap = str(parsed.get("caption", "")).strip()
    if not cap:
        raise ValueError("empty caption")
    return cap[:220]


class ExplainMoodBody(BaseModel):
    deviceId: str = Field(..., min_length=1, max_length=128)
    mood: str = Field(...)
    localDate: str = Field(..., description="User's local calendar date YYYY-MM-DD")
    timeZoneId: str = Field(..., min_length=1, max_length=128)
    restingBpm: float | None = Field(None, ge=30, le=120)
    recentBpms: list[float] | None = Field(None, max_length=64)
    classifierReason: str | None = Field(None, max_length=512)
    analyzeSource: str | None = Field(None, max_length=64)
    customMoodName: str | None = Field(
        None,
        max_length=48,
        description="User-entered mood label (Customize mood); drives caption tone",
    )

    @field_validator("customMoodName")
    @classmethod
    def strip_custom_mood(cls, v: str | None) -> str | None:
        if v is None:
            return None
        s = v.strip()
        return s if s else None

    @field_validator("mood")
    @classmethod
    def mood_ok_explain(cls, v: str) -> str:
        m = v.lower().strip()
        if m not in MOODS:
            raise ValueError("mood must be one of calm, stressed, happy, sad")
        return m

    @field_validator("recentBpms")
    @classmethod
    def clamp_bpms(cls, v: list[float] | None) -> list[float] | None:
        if not v:
            return None
        out: list[float] = []
        for x in v[:64]:
            try:
                fv = float(x)
                if not math.isfinite(fv):
                    continue
                out.append(max(30.0, min(230.0, fv)))
            except (TypeError, ValueError):
                continue
        return out or None


_INDEX_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Cardiac Mood Light API</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; color: #111; }
    h1 { font-weight: 600; }
    a { color: #0a58ca; }
    code { background: #f4f4f5; padding: 0.1em 0.35em; border-radius: 4px; font-size: 0.9em; }
    ul { padding-left: 1.25rem; }
  </style>
</head>
<body>
  <h1>Cardiac Mood Light</h1>
  <p>FastAPI backend for BPM-window mood classification and ESP32 LED state.</p>
  <ul>
    <li><a href="/health">Health (JSON)</a> — <code>GET /health</code></li>
    <li><a href="/v1/cardiac/health">Legacy health</a> — <code>GET /v1/cardiac/health</code></li>
    <li><a href="/docs">OpenAPI docs</a> — <code>GET /docs</code></li>
    <li><code>POST /v1/cardiac/analyze</code> — analyze BPM window (requires <code>x-api-key</code> when configured)</li>
    <li><code>POST /v1/cardiac/manual</code> — set color/brightness from phone (requires <code>x-api-key</code> when configured)</li>
    <li><code>POST /v1/cardiac/explain-mood</code> — Claude mood caption for the iOS lamp UI (requires <code>x-api-key</code> when configured)</li>
    <li><code>GET /v1/cardiac/latest</code> — latest mood for ESP32 (requires <code>x-api-key</code> when configured)</li>
    <li><a href="/app/">Little Lamp web tester</a> — same flows as the iOS app (manual lamp, analyze simulator, mood caption)</li>
  </ul>
</body>
</html>"""


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    """Human-readable landing page for browser and uptime checks."""
    return _INDEX_HTML


@app.get("/health")
def health_root() -> dict[str, str]:
    """Simple health check for load balancers (e.g. Railway)."""
    return {"status": "ok", "service": "cardiac-mood-light"}


@app.get("/v1/cardiac/health")
def health() -> dict[str, str]:
    return {"status": "ok", "service": "cardiac-mood-light"}


@app.post("/v1/cardiac/analyze")
async def analyze(
    body: AnalyzeBody,
    x_api_key: str | None = Header(default=None, alias="x-api-key"),
) -> dict[str, Any]:
    require_api_key(x_api_key)

    bpms = [s.bpm for s in body.samples]
    tz_id = (body.timeZoneId or "").strip() or None
    period = _now_in_user_tz(tz_id)["period"] if tz_id else None

    mood: str | None = None
    reason = ""
    source = "claude"

    if ANTHROPIC_API_KEY:
        try:
            mood, reason = await classify_claude(body.restingBpm, bpms, tz_id)
        except Exception as e:
            log.warning("Claude failed, using heuristic: %s", e)
            source = "heuristic_after_claude_error"
            mood, reason = classify_heuristic(bpms, body.restingBpm, period=period)
    else:
        source = "heuristic"
        mood, reason = classify_heuristic(bpms, body.restingBpm, period=period)

    state = pack_state(body.deviceId, mood, reason, source)
    return {
        "ok": True,
        "mood": state["mood"],
        "label": state["label"],
        "color": state["color"],
        "brightness": state["brightness"],
        "reason": state["reason"],
        "source": state["source"],
        "updatedAt": state["updatedAt"],
        "powerOn": state["powerOn"],
        "blinkEnabled": state["blinkEnabled"],
        "blinkBpm": state["blinkBpm"],
    }


@app.post("/v1/cardiac/manual")
async def manual_lamp(
    body: ManualLampBody,
    x_api_key: str | None = Header(default=None, alias="x-api-key"),
) -> dict[str, Any]:
    """Push lamp state so ESP32 picks it up on the next GET /v1/cardiac/latest poll."""
    require_api_key(x_api_key)
    state = pack_manual(
        body.deviceId,
        body.mood,
        body.brightness,
        body.color,
        power_on=body.powerOn,
        blink_enabled=body.blinkEnabled,
        blink_bpm=body.blinkBpm,
        custom_label=body.moodLabel,
    )
    return {
        "ok": True,
        "mood": state["mood"],
        "label": state["label"],
        "color": state["color"],
        "brightness": state["brightness"],
        "reason": state["reason"],
        "source": state["source"],
        "updatedAt": state["updatedAt"],
        "powerOn": state["powerOn"],
        "blinkEnabled": state["blinkEnabled"],
        "blinkBpm": state["blinkBpm"],
    }


@app.post("/v1/cardiac/explain-mood")
async def explain_mood(
    body: ExplainMoodBody,
    x_api_key: str | None = Header(default=None, alias="x-api-key"),
) -> dict[str, Any]:
    """Generate a short user-facing sentence for why the lamp feels like this mood (Claude or fallback)."""
    require_api_key(x_api_key)

    rb = body.recentBpms
    resting = body.restingBpm
    cr_raw = (body.classifierReason or "").strip()
    junk_reasons = {"", "manual_ios", "claude", "too few samples"}
    cr_signal = cr_raw if cr_raw not in junk_reasons else ""

    has_hr = bool(rb) or (resting is not None) or bool(cr_signal)

    now_ctx = _now_in_user_tz(body.timeZoneId)
    # Fallback copy uses the same calendar date as Claude (timezone-aware on server)
    local_date_for_fallback = now_ctx["date_iso"]

    h_compact: dict[str, Any] | None = None
    if has_hr:
        h_compact = {}
        if resting is not None:
            h_compact["r"] = round(float(resting), 1)
        if rb:
            tail = rb[-10:]
            h_compact["b"] = [round(float(x), 1) for x in tail]
        if cr_signal:
            h_compact["c"] = cr_signal[:100]
        src = (body.analyzeSource or "").strip()
        if src:
            h_compact["s"] = src[:24]
        if len(h_compact) == 0:
            h_compact = None

    # Minimal user message: short keys, tiny payload (u=user mood word when set)
    payload_user: dict[str, Any] = {
        "m": body.mood,
        "n": now_ctx["one_liner"],
        "h": h_compact,
    }
    cu_in = (body.customMoodName or "").strip()[:48]
    if cu_in:
        payload_user["u"] = cu_in
        payload_user["uf"] = 0 if _label_likely_gibberish(cu_in) else 1

    caption = ""
    if ANTHROPIC_API_KEY:
        try:
            caption = await explain_mood_caption_claude(payload_user)
        except Exception as e:
            log.warning("Explain mood Claude failed, using fallback: %s", e)
            caption = _fallback_explain_caption(
                body.mood,
                has_hr=has_hr,
                classifier_reason=(cr_signal or None),
                recent_bpms=rb,
                local_date=local_date_for_fallback,
                custom_mood_name=body.customMoodName,
            )
    else:
        caption = _fallback_explain_caption(
            body.mood,
            has_hr=has_hr,
            classifier_reason=(cr_signal or None),
            recent_bpms=rb,
            local_date=local_date_for_fallback,
            custom_mood_name=body.customMoodName,
        )

    return {"ok": True, "caption": caption}


@app.get("/v1/cardiac/latest")
def latest(
    deviceId: str = Query(..., min_length=1),
    x_api_key: str | None = Header(default=None, alias="x-api-key"),
) -> dict[str, Any]:
    require_api_key(x_api_key)
    row = _STORE.get(deviceId)
    if not row:
        raise HTTPException(status_code=404, detail="no_state_for_device")
    return {
        "mood": row["mood"],
        "label": row["label"],
        "color": row["color"],
        "brightness": row["brightness"],
        "updatedAt": row["updatedAt"],
        "powerOn": row.get("powerOn", True),
        "blinkEnabled": row.get("blinkEnabled", False),
        "blinkBpm": float(row.get("blinkBpm", 72.0)),
    }


_WEB_DIR = Path(__file__).resolve().parent / "web"
if _WEB_DIR.is_dir():
    app.mount(
        "/app",
        StaticFiles(directory=str(_WEB_DIR), html=True),
        name="little_lamp_web",
    )
