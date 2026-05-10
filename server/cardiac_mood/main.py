"""
Cardiac Mood Light API — BPM window → Claude (optional) → mood + LED state.
"""

from __future__ import annotations

import json
import logging
import math
import os
import time
from pathlib import Path
from typing import Any

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
CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL", "claude-sonnet-4-20250514")

MOODS = frozenset({"calm", "stressed", "happy", "sad"})

# Fixed palette — server assigns; Claude only picks mood id.
STYLE: dict[str, dict[str, Any]] = {
    "calm": {"label": "Calm (baseline)", "color": "#FFD700", "brightness": 180},
    "stressed": {"label": "Escalating / Stressed", "color": "#FF0000", "brightness": 255},
    "happy": {"label": "Happy / Energetic", "color": "#FF69B4", "brightness": 220},
    "sad": {"label": "Sad / Drained", "color": "#4169E1", "brightness": 115},
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


CLAUDE_SYSTEM = """You classify a short chronological heart-rate (BPM) window into exactly one mood for ambient lighting rules.

Categories (pick exactly one JSON value for "mood"):
- calm: Steady BPM near baseline, low jitter (e.g. [70, 71, 70, 72, 70]).
- stressed: Sudden sharp erratic BPM spike upward without gradual buildup while implied at rest (e.g. [72, 75, 88, 95, 102]).
- happy: Smooth gradual rise to a sustained higher BPM / flow excitement (e.g. [75, 78, 82, 85, 86]).
- sad: BPM slightly below the user's normal resting baseline, very flat and low energy (e.g. [64, 63, 63, 64, 62]).

You receive resting_bpm (may be null) and bpms oldest→newest. Prefer physiological pattern shape over stereotypes.

Respond with ONLY a JSON object, no markdown, in this exact shape:
{"mood":"calm|stressed|happy|sad","reason":"<one short phrase>"}
"""


async def classify_claude(resting_bpm: float | None, bpms: list[float]) -> tuple[str, str]:
    payload = {"resting_bpm": resting_bpm, "bpms": bpms}
    user_text = json.dumps(payload, separators=(",", ":"))

    body = {
        "model": CLAUDE_MODEL,
        "max_tokens": 256,
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


EXPLAIN_MOOD_SYSTEM = """You write UI microcopy for "Little Lamp", a cozy heart-rate aware accent light.

The user sees one of these moods: calm, stressed, happy, sad.

Output exactly ONE friendly sentence (max 260 characters) that explains why the lamp might feel like this mood right now.

Rules:
- When heart_rate_context is present (resting BPM, recent BPM samples, classifier_reason): still blend in everyday life — do NOT rely on pulse alone. In the same sentence, combine (a) gentle, non-clinical hints about rhythm or BPM pattern (steady, uptick, jitter, etc.) with (b) at least one contextual angle informed by local_date and time_zone — e.g. weekday vs weekend energy, season or holiday-season vibe, morning vs evening feel, indoor coziness vs bright-day mood, weather-ish atmosphere (without claiming a live forecast). No diagnoses or medical claims.
- When heart_rate_context is absent or empty: do NOT claim you measured vitals. Use 2–3 playful everyday possibilities — weather vibe, weekend vs weekday, seasonal hint, time-of-day energy — inclusive and light.
- Tone matches the mood (calm = soft; stressed = sympathetic; happy = warm; sad = gentle).
- Plain text only — no markdown, no bullet symbols.

Respond ONLY with JSON in this exact shape:
{"caption":"<single sentence>"}
"""


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


def _fallback_explain_caption(
    mood: str,
    *,
    has_hr: bool,
    classifier_reason: str | None,
    recent_bpms: list[float] | None,
    local_date: str,
) -> str:
    """Deterministic copy when Claude is unavailable; blends HR hints with everyday context when both apply."""
    cr = (classifier_reason or "").strip()
    junk = {"", "manual_ios", "claude", "too few samples"}
    everyday = _everyday_context_fragment(local_date, mood)

    hr_part: str | None = None
    if has_hr and recent_bpms:
        avg = sum(recent_bpms) / len(recent_bpms)
        if cr and cr not in junk:
            hr_part = f"Your recent pulse looked {cr}, with beats near {avg:.0f} BPM"
        else:
            hr_part = f"Recent heart-rate samples hovered near {avg:.0f} BPM"
    elif has_hr and cr and cr not in junk:
        hr_part = f"Your pulse pattern looked {cr}"

    if hr_part:
        return f"{hr_part} — {everyday}."
    return f"{everyday}."


async def explain_mood_caption_claude(payload_user: dict[str, Any]) -> str:
    body = {
        "model": CLAUDE_MODEL,
        "max_tokens": 320,
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
    return cap[:400]


class ExplainMoodBody(BaseModel):
    deviceId: str = Field(..., min_length=1, max_length=128)
    mood: str = Field(...)
    localDate: str = Field(..., description="User's local calendar date YYYY-MM-DD")
    timeZoneId: str = Field(..., min_length=1, max_length=128)
    restingBpm: float | None = Field(None, ge=30, le=120)
    recentBpms: list[float] | None = Field(None, max_length=64)
    classifierReason: str | None = Field(None, max_length=512)
    analyzeSource: str | None = Field(None, max_length=64)

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

    mood: str | None = None
    reason = ""
    source = "claude"

    if ANTHROPIC_API_KEY:
        try:
            mood, reason = await classify_claude(body.restingBpm, bpms)
        except Exception as e:
            log.warning("Claude failed, using heuristic: %s", e)
            source = "heuristic_after_claude_error"
            mood, reason = classify_heuristic(bpms, body.restingBpm)
    else:
        source = "heuristic"
        mood, reason = classify_heuristic(bpms, body.restingBpm)

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

    heart_rate_context: dict[str, Any] | None = None
    if has_hr:
        heart_rate_context = {
            "resting_bpm": resting,
            "recent_bpms_oldest_to_newest": list(rb or []),
            "classifier_reason": cr_signal,
            "analyze_source": (body.analyzeSource or "").strip(),
        }

    payload_user = {
        "mood": body.mood,
        "local_date": body.localDate,
        "time_zone": body.timeZoneId,
        "heart_rate_context": heart_rate_context,
    }

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
                local_date=body.localDate,
            )
    else:
        caption = _fallback_explain_caption(
            body.mood,
            has_hr=has_hr,
            classifier_reason=(cr_signal or None),
            recent_bpms=rb,
            local_date=body.localDate,
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
