# CardiacMoodLED (ESP32 + WS2812)

Polls `GET /v1/cardiac/latest?deviceId=...` and sets the strip to the server’s `color` and `brightness`.

## Arduino IDE

1. Install **FastLED** and **ArduinoJson** from the Library Manager.
2. Board: ESP32 Dev Module (or your variant).
3. Edit `CardiacMoodLED.ino`: set `WIFI_SSID`, `WIFI_PASSWORD`, `CARDIAC_HOST`, `DEVICE_ID`, `API_KEY`.
4. Adjust `LED_PIN`, `NUM_LEDS`, `USE_HTTPS` as needed.

## HTTPS (Railway)

Production defaults: `USE_HTTPS true`, `CARDIAC_PORT 443`, host `cardiac-mood-light-production.up.railway.app`. The sketch uses `WiFiClientSecure` with `setInsecure()` for prototyping. For a local dev server on LAN, set `USE_HTTPS false`, your LAN IP, and port (e.g. `8080`).
