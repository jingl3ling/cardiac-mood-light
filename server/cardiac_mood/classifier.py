"""
Mood from heart rate — optimized for **one BPM reading** vs resting, with optional
short windows when Apple Watch / Health returns several samples (e.g. workouts).

Not clinical advice; crude heuristics for lamp palette only.
"""

from __future__ import annotations

import math
import statistics
from typing import Literal, Tuple

Mood = Literal["calm", "stressed", "happy", "sad"]


def _safe_floats(bpms: list[float]) -> list[float]:
    out: list[float] = []
    for x in bpms:
        try:
            v = float(x)
            if math.isfinite(v):
                out.append(max(30.0, min(230.0, v)))
        except (TypeError, ValueError):
            continue
    return out


def _effective_resting(resting_bpm: float | None, xs: list[float]) -> float:
    if resting_bpm is not None:
        return float(resting_bpm)
    if len(xs) >= 3:
        return float(statistics.median(xs))
    # Unknown resting with only 1–2 points — mild prior so delta-vs-rest still runs.
    return 72.0


def _classify_single(bpm: float, rest: float) -> Tuple[Mood, str]:
    """One instantaneous HR vs resting (main phone / Health path)."""
    delta = bpm - rest
    if bpm <= 54 or delta <= -15:
        return "sad", "below typical resting energy"
    if delta >= 30 or bpm >= 120:
        return "stressed", "well above resting"
    if 10 <= delta <= 42 and bpm >= 76:
        return "happy", "lifted above resting pace"
    if abs(delta) <= 11 and 56 <= bpm <= 100:
        return "calm", "near resting pace"
    if delta >= 18:
        return "stressed", "elevated versus resting"
    if delta <= -8:
        return "sad", "muted versus resting"
    return "calm", "steady versus resting"


def classify_heuristic(
    bpms: list[float],
    resting_bpm: float | None,
    *,
    period: str | None = None,
) -> Tuple[Mood, str]:
    """
    ``period`` is morning|afternoon|evening|night — optional soft context from caller TZ.
    """
    xs = _safe_floats(bpms)
    if not xs:
        return "calm", "no samples"

    rest = _effective_resting(resting_bpm, xs)

    # Single reading — compare to resting (+ tiny optional time hint).
    if len(xs) == 1:
        mood, reason = _classify_single(xs[0], rest)
        if period == "night" and mood == "happy":
            return "calm", "quiet pulse vs resting"
        return mood, reason

    last = xs[-1]
    spread = max(xs) - min(xs)
    mean = statistics.mean(xs)
    slope = xs[-1] - xs[0]

    # Several readings (e.g. workout buffer): volatility + trend.
    if spread >= 15.0:
        return "stressed", "pulse swinging across the window"
    if len(xs) >= 3 and slope >= 10.0 and spread >= 8.0:
        return "happy", "building HR across samples"
    if len(xs) >= 3 and mean <= rest - 6 and spread <= 6.0:
        return "sad", "held low across samples"
    if len(xs) == 2 and abs(xs[1] - xs[0]) >= 18:
        return "stressed", "large jump between two readings"

    # Fall back to latest beat vs resting.
    return _classify_single(last, rest)
