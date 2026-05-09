"""
Cardiac Mood Light API — BPM window → Claude (optional) → mood + LED state.
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.responses import HTMLResponse
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


def pack_manual(
    device_id: str,
    mood: str,
    brightness: int,
    color_override: str | None,
    *,
    power_on: bool,
    blink_enabled: bool,
    blink_bpm: float,
) -> dict[str, Any]:
    st = STYLE[mood]
    color = color_override if color_override else st["color"]
    bpm = max(30.0, min(220.0, float(blink_bpm)))
    state = {
        "deviceId": device_id,
        "mood": mood,
        "label": st["label"],
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
    <li><code>GET /v1/cardiac/latest</code> — latest mood for ESP32 (requires <code>x-api-key</code> when configured)</li>
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
