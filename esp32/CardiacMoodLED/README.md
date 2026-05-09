# CardiacMoodLED (ESP32 + WS2812)

Polls `GET /v1/cardiac/latest?deviceId=...` and sets the strip to the server’s `color` and `brightness`.

## Arduino IDE

1. Install **FastLED** and **ArduinoJson** from the Library Manager.
2. Board: ESP32 Dev Module (or your variant).
3. Edit `CardiacMoodLED.ino`: set `WIFI_SSID`, `WIFI_PASSWORD`, `CARDIAC_HOST`, `DEVICE_ID`, `API_KEY`.
4. Adjust `LED_PIN`, `NUM_LEDS`, `USE_HTTPS` as needed.

## HTTPS

For `USE_HTTPS true`, the sketch uses `WiFiClientSecure` with certificate validation disabled for prototyping (`setInsecure()`). Use HTTP to a local dev server when testing on LAN.
