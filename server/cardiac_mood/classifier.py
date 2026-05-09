"""
Deterministic BPM-window mood classifier — used when Claude is unavailable or
to validate extremes. Tunings mirror the user's example arrays.
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
                out.append(v)
        except (TypeError, ValueError):
            continue
    return out


def classify_heuristic(bpms: list[float], resting_bpm: float | None) -> Tuple[Mood, str]:
    xs = _safe_floats(bpms)
    if len(xs) < 3:
        return "calm", "too few samples"

    rest = resting_bpm if resting_bpm is not None else statistics.median(xs)
    mean = statistics.mean(xs)
    spread = max(xs) - min(xs)
    var = statistics.pvariance(xs) if len(xs) >= 2 else 0.0
    stdev = math.sqrt(var)
    deltas = [xs[i + 1] - xs[i] for i in range(len(xs) - 1)]
    max_up = max((d for d in deltas if d > 0), default=0.0)
    max_down = min((d for d in deltas if d < 0), default=0.0)
    max_step = max(abs(d) for d in deltas) if deltas else 0.0
    slope = (xs[-1] - xs[0]) / max(1, len(xs) - 1)

    # Sad: below baseline, very flat (e.g. [64,63,63,64,62])
    if mean <= rest - 3.5 and spread <= 2.5 and stdev <= 1.2:
        return "sad", "flat and below resting"

    # Stressed: sharp erratic spike(s) (e.g. [72,75,88,95,102])
    if max_step >= 7.0 or (max_up >= 6.0 and sum(1 for d in deltas if d >= 4) >= 2):
        return "stressed", "large rapid BPM jump(s)"

    # Happy: smooth gradual rise, elevated vs start (e.g. [75,78,82,85,86])
    if slope >= 1.8 and mean >= rest - 2 and max_step <= 4.5 and xs[-1] >= xs[0] + 5:
        return "happy", "smooth upward trend with moderate steps"

    # Calm: near resting, low spread (e.g. [70,71,70,72,70])
    if spread <= 4.0 and abs(mean - rest) <= 8.0 and max_step <= 4.0:
        return "calm", "steady near baseline"

    # Default: leaning calm if close to resting else stressed if rising fast
    if slope > 3 and spread > 5:
        return "stressed", "rising with wide swing"
    if mean < rest - 2:
        return "sad", "muted relative to resting"
    return "calm", "default steady"
