# Cardiac Mood Light

Apple Watch collects a short BPM window; the iPhone adds **resting heart rate** from HealthKit and calls the backend. The backend uses **Claude** (when `ANTHROPIC_API_KEY` is set) with a **heuristic fallback** to classify mood, then maps to fixed colors and brightness. An **ESP32** with **WS2812** polls the latest mood for your lamp.

## Mood → LED

| Mood | Color | Brightness (0–255) |
|------|--------|---------------------|
| Calm | `#FFD700` | 180 |
| Stressed | `#FF0000` | 255 |
| Happy | `#FF69B4` | 220 |
| Sad | `#4169E1` | 115 |

## Deploy on Railway

This repo is a **monorepo**. Railpack looks at the repository root, so it does not see `server/requirements.txt` unless you isolate the backend.

Choose one approach:

1. **Recommended (no dashboard tweak):** Commit the root [`Dockerfile`](Dockerfile) and [`railway.json`](railway.json). Railway will build with **Dockerfile** and run Uvicorn with `$PORT`.
2. **Alternative:** In the Railway service **Settings → Root Directory**, set **`server`**. Then Railpack detects Python from `server/requirements.txt`.

Set environment variables in Railway: `API_KEY` (optional), `ANTHROPIC_API_KEY` (optional), `CLAUDE_MODEL` (optional).

**Production URL:** `https://cardiac-mood-light-production.up.railway.app`  
- Browser / index: `GET /`  
- Health (JSON): `GET /health`  
- API docs: `GET /docs`

The iOS app [`Config.swift`](ios/CardiacMood/Config.swift) defaults to this URL; override for local dev.

## Backend

```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# Set API_KEY and optionally ANTHROPIC_API_KEY
uvicorn cardiac_mood.main:app --host 0.0.0.0 --port 8080
```

- `POST /v1/cardiac/analyze` — body: `{ "deviceId": "...", "restingBpm": 68.0, "samples": [ { "t": "ISO8601", "bpm": 72 } ] }` — header `x-api-key` if configured.
- `GET /v1/cardiac/latest?deviceId=...` — same header; returns `mood`, `color`, `brightness`, `label`, `updatedAt`.

## iOS + watchOS

Open `ios/CardiacMood.xcodeproj` in Xcode. Use the shared scheme **CardiacMood** (not a Mac-only target). Set your **team**, **bundle IDs** if needed, and edit `Config.swift` in both the iOS and Watch targets (`baseURL`, `apiKey`, `deviceId`).

If the run destination menu only showed **My Mac**, the iOS app target was missing an explicit iPhone SDK — that is fixed in the project (`SDKROOT = iphoneos`, no macOS code-signing on the iPhone app). You should see your **iPhone** and **iOS Simulator** in the device list.

**Signing:** The iOS app uses the **HealthKit** capability and must use a **development / distribution certificate** with **Automatically manage signing** enabled. The **Watch** target uses the same **Team** as the iPhone app (required for embedded watchOS apps). If Xcode warns about entitlements, open the **CardiacMood** target → **Signing & Capabilities**, choose your **Team**, and ensure the **CardiacMoodWatch** target has the same team. To change the checked-in team ID, edit `DEVELOPMENT_TEAM` in the Xcode project or set `DEV_TEAM` in [`ios/generate_project.py`](ios/generate_project.py) before regenerating.

The Xcode project file is generated from `uids.txt` for stable 24-hex IDs. Regenerate with:

`python3 ios/generate_project.py`

Build the iOS app from Xcode with a **paired iOS + watchOS simulator** (or device + watch). Command-line `xcodebuild` for `iphonesimulator` alone can fail on the Watch target unless the watch simulator runtime is available and selected as the paired destination in Xcode.

Enable **HealthKit** capability on the iOS app. Run the Watch app (workout session provides live heart rate), run the iPhone app to receive windows over WatchConnectivity and push analysis to the server.

## ESP32

See [esp32/CardiacMoodLED/README.md](esp32/CardiacMoodLED/README.md). Set Wi‑Fi, `CARDIAC_HOST`, `DEVICE_ID`, and `API_KEY` to match the phone/server.

## Privacy

The MVP stores only the **latest mood per `deviceId`** in memory on the server; it does not persist raw Health data.
