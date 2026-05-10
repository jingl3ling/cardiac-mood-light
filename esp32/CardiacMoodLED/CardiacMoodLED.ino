/**
 * Cardiac Mood Light — ESP32 + WS2812 from GET /v1/cardiac/latest
 *
 * Set WIFI_*, CARDIAC_HOST, DEVICE_ID, API_KEY below.
 */

#include <WiFi.h>
#include <WiFiClient.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <FastLED.h>
#include <math.h>

#define CARDIAC_DEBUG 1

static const char *WIFI_SSID = "ARRIS-1165";
static const char *WIFI_PASSWORD = "005340231883";

// Host only, no scheme (e.g. "192.168.1.10" or "api.example.com")
static const char *CARDIAC_HOST = "cardiac-mood-light-production.up.railway.app";
static const uint16_t CARDIAC_PORT = 443;
static const bool USE_HTTPS = true;

static const char *DEVICE_ID = "device-001";
static const char *API_KEY = "dev-change-me";

static const int LED_PIN = 13;
static const int NUM_LEDS = 8;
static const unsigned long POLL_MS = 700;
static const unsigned long POLL_MS_BLINK = 400;
static const unsigned long WIFI_TIMEOUT_MS = 30000;
static const unsigned long WIFI_RETRY_MS = 10000;

static CRGB leds[NUM_LEDS];
static CRGB g_solid(20, 20, 30);
static unsigned long lastFetch = 0;
static unsigned long lastWifiAttempt = 0;
static bool g_wifiUp = false;
static bool g_lastFetchOk = false;

static bool g_powerOn = true;
static bool g_blinkEnabled = false;
static float g_blinkBpm = 72.0f;
static int g_masterBrightness = 180;

static bool isPlaceholderCredentials() {
  return (WIFI_SSID[0] == '\0' || strcmp(WIFI_SSID, "CHANGE_ME") == 0 ||
          strcmp(WIFI_PASSWORD, "CHANGE_ME") == 0);
}

static void showNoWifiCreds() {
  fill_solid(leds, NUM_LEDS, CRGB(255, 215, 0));
  FastLED.setBrightness(120);
  FastLED.show();
}

static void showWifiConnecting() {
  uint8_t p = 80 + (uint8_t)(60 * (1.0f + sinf(millis() * 0.004f)) * 0.5f);
  fill_solid(leds, NUM_LEDS, CRGB(p, (uint8_t)(p * 0.84f), 0));
  FastLED.show();
}

/** Brief GET failure: hold last mood color, dimmed — no red flash (avoids alarming random red). */
static void showHttpFail() {
  fill_solid(leds, NUM_LEDS, g_solid);
  int dim = max(12, g_masterBrightness / 5);
  if (dim > 255) dim = 255;
  FastLED.setBrightness((uint8_t)dim);
  FastLED.show();
}

static bool tryConnectWifi() {
  if (isPlaceholderCredentials()) {
    g_wifiUp = false;
    Serial.println(F("Set WIFI_SSID and WIFI_PASSWORD."));
    return false;
  }
  WiFi.mode(WIFI_STA);
  WiFi.disconnect(true);
  delay(100);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print(F("WiFi: "));
  Serial.println(WIFI_SSID);

  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED) {
    if (millis() - start > WIFI_TIMEOUT_MS) {
      Serial.println(F("WiFi timeout"));
      g_wifiUp = false;
      return false;
    }
    delay(300);
    Serial.print(".");
  }
  Serial.println();
  Serial.print(F("IP: "));
  Serial.println(WiFi.localIP());
  g_wifiUp = true;
  return true;
}

static void renderLeds() {
  if (!g_powerOn) {
    fill_solid(leds, NUM_LEDS, CRGB::Black);
    FastLED.setBrightness(0);
    FastLED.show();
    return;
  }

  if (g_blinkEnabled) {
    float bpm = g_blinkBpm;
    if (bpm < 30.0f) bpm = 30.0f;
    if (bpm > 220.0f) bpm = 220.0f;
    // One heartbeat per full cycle (matches BPM from phone / Health → GET latest → blinkBpm).
    float periodMs = 60000.0f / bpm;
    float phase = fmodf((float)millis(), periodMs) / periodMs;
    // One period = one heartbeat: first half off (dark), second half on (light) — two states only.
    bool lightHalf = phase >= 0.5f;
    int hi = g_masterBrightness;
    if (hi < 1) hi = 1;
    if (hi > 255) hi = 255;
    int b = lightHalf ? hi : 0;
    if (b < 0) b = 0;
    if (b > 255) b = 255;
    fill_solid(leds, NUM_LEDS, g_solid);
    FastLED.setBrightness((uint8_t)b);
    FastLED.show();
    return;
  }

  if (!g_lastFetchOk) {
    showHttpFail();
    return;
  }

  fill_solid(leds, NUM_LEDS, g_solid);
  int bb = g_masterBrightness;
  if (bb < 0) bb = 0;
  if (bb > 255) bb = 255;
  FastLED.setBrightness((uint8_t)bb);
  FastLED.show();
}

static bool parseColorHex(const char *s, CRGB &out) {
  if (!s) return false;
  while (*s == ' ' || *s == '\t') s++;
  if (*s == '#') s++;
  if (strlen(s) != 6) return false;
  for (int i = 0; i < 6; i++) {
    if (!isxdigit((unsigned char)s[i])) return false;
  }
  char *end = nullptr;
  unsigned long v = strtoul(s, &end, 16);
  if (end != s + 6 || v > 0xFFFFFF) return false;
  out = CRGB((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
  return true;
}

static bool fetchCardiac() {
  if (!g_wifiUp) return false;

  char path[160];
  snprintf(path, sizeof(path), "/v1/cardiac/latest?deviceId=%s", DEVICE_ID);

#if CARDIAC_DEBUG
  Serial.print(F("GET "));
  Serial.print(USE_HTTPS ? "https://" : "http://");
  Serial.print(CARDIAC_HOST);
  Serial.println(path);
#endif

  HTTPClient http;
  WiFiClient plain;
  WiFiClientSecure secure;

  if (USE_HTTPS) {
    secure.setInsecure();
    if (!http.begin(secure, CARDIAC_HOST, CARDIAC_PORT, path, true)) {
      Serial.println(F("http.begin(https) failed"));
      g_lastFetchOk = false;
      return false;
    }
  } else {
    if (!http.begin(plain, CARDIAC_HOST, CARDIAC_PORT, path, false)) {
      Serial.println(F("http.begin(http) failed"));
      g_lastFetchOk = false;
      return false;
    }
  }

  if (API_KEY[0] != '\0') {
    http.addHeader("x-api-key", API_KEY);
  }
  http.setTimeout(4500);
  int code = http.GET();
  String body = http.getString();
  http.end();

#if CARDIAC_DEBUG
  Serial.print(F("HTTP "));
  Serial.print(code);
  Serial.print(F(" len="));
  Serial.println(body.length());
#endif

  if (code != 200) {
    g_lastFetchOk = false;
    return false;
  }

  StaticJsonDocument<512> doc;
  if (deserializeJson(doc, body)) {
    Serial.println(F("JSON parse error"));
    g_lastFetchOk = false;
    return false;
  }

  const char *col = doc["color"].as<const char *>();
  int bright = doc["brightness"].is<int>() ? doc["brightness"].as<int>() : 180;
  if (bright < 0) bright = 0;
  if (bright > 255) bright = 255;
  g_masterBrightness = bright;

  g_powerOn = doc["powerOn"] | true;
  g_blinkEnabled = doc["blinkEnabled"] | false;
  if (!doc["blinkBpm"].isNull()) {
    g_blinkBpm = doc["blinkBpm"].as<float>();
  }
  if (g_blinkBpm < 30.0f) g_blinkBpm = 30.0f;
  if (g_blinkBpm > 220.0f) g_blinkBpm = 220.0f;

  CRGB next;
  if (!col || !parseColorHex(col, next)) {
    g_lastFetchOk = false;
    return false;
  }

  g_solid = next;
  g_lastFetchOk = true;
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println(F("\n=== CardiacMoodLED ==="));

  FastLED.addLeds<WS2812, LED_PIN, GRB>(leds, NUM_LEDS);
  FastLED.setBrightness(120);
  fill_solid(leds, NUM_LEDS, CRGB(10, 10, 15));
  FastLED.show();

  if (!isPlaceholderCredentials()) {
    (void)tryConnectWifi();
  }
  lastWifiAttempt = millis();
  lastFetch = 0;
}

void loop() {
  if (isPlaceholderCredentials()) {
    showNoWifiCreds();
    return;
  }

  if (WiFi.status() != WL_CONNECTED) {
    g_wifiUp = false;
    if (millis() - lastWifiAttempt > WIFI_RETRY_MS) {
      lastWifiAttempt = millis();
      Serial.println(F("Retry WiFi..."));
      (void)tryConnectWifi();
    } else {
      showWifiConnecting();
    }
    return;
  }
  g_wifiUp = true;

  unsigned long now = millis();
  unsigned long interval = (g_blinkEnabled && g_powerOn) ? POLL_MS_BLINK : POLL_MS;
  if (now - lastFetch >= interval) {
    lastFetch = now;
    if (!fetchCardiac()) {
      Serial.println(F("fetch failed"));
    }
  }

  renderLeds();
}
