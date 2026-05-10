(() => {
  const STORAGE = {
    baseUrl: "littleLampBaseUrl",
    apiKey: "littleLampApiKey",
    deviceId: "littleLampDeviceId",
    appearance: "littleLampAppearance",
    fixedAppearance: "littleLampFixedAppearance",
    moodInsightCommitted: "littleLampMoodInsightCommitted",
  };

  const PRESETS = [
    { id: "calm", title: "Calm", hex: "#FFD700", icon: "🍃" },
    { id: "stressed", title: "Stressed", hex: "#FF0000", icon: "⚡" },
    { id: "happy", title: "Happy", hex: "#FF69B4", icon: "☀️" },
    { id: "sad", title: "Sad", hex: "#4169E1", icon: "🌧️" },
  ];

  const DEBOUNCE_MS = 260;

  const state = {
    selectedMoodId: "calm",
    lampBrightness: 120,
    lampPowerOn: true,
    blinkEnabled: false,
    blinkBpm: 72,
    customColorEnabled: false,
    spectrumHue: 0,
    customMoodName: "",
    customMoodInsightCommitted: "",
    lastMood: "—",
    lastLabel: "—",
    lastReason: "",
    lastAnalyzeSource: "",
    moodInsight: "",
    insightRestingBpm: null,
    insightRecentBpms: null,
    insightClassifierReason: null,
    manualGen: 0,
    insightGen: 0,
    debounceTimer: null,
  };

  function $(id) {
    return document.getElementById(id);
  }

  function loadSettings() {
    $("baseUrl").value = localStorage.getItem(STORAGE.baseUrl) ?? "";
    $("apiKey").value = localStorage.getItem(STORAGE.apiKey) ?? "";
    $("deviceId").value = localStorage.getItem(STORAGE.deviceId) ?? "device-001";

    const fixed = localStorage.getItem(STORAGE.fixedAppearance) === "1";
    $("fixedAppearance").checked = fixed;
    $("appearancePick").style.display = fixed ? "block" : "none";

    const app = localStorage.getItem(STORAGE.appearance) ?? "system";
    document.querySelectorAll(".segmented button[data-appearance]").forEach((b) => {
      b.classList.toggle("active", b.dataset.appearance === app);
    });
    if (fixed && (app === "light" || app === "dark")) {
      applyTheme(app);
    } else {
      applyTheme("system");
    }
  }

  function saveSettings() {
    localStorage.setItem(STORAGE.baseUrl, $("baseUrl").value.trim());
    localStorage.setItem(STORAGE.apiKey, $("apiKey").value);
    localStorage.setItem(STORAGE.deviceId, $("deviceId").value.trim() || "device-001");
  }

  /** @returns {string} device id */
  function deviceId() {
    return $("deviceId").value.trim() || "device-001";
  }

  function apiBase() {
    const u = $("baseUrl").value.trim();
    return u.replace(/\/+$/, "");
  }

  function apiUrl(path) {
    const base = apiBase();
    if (!base) return path;
    return base + path;
  }

  function apiHeaders() {
    const h = { "Content-Type": "application/json" };
    const key = $("apiKey").value.trim();
    if (key) h["x-api-key"] = key;
    return h;
  }

  async function apiFetch(path, options = {}) {
    const res = await fetch(apiUrl(path), {
      ...options,
      headers: { ...apiHeaders(), ...options.headers },
    });
    if (!res.ok) {
      const t = await res.text();
      throw new Error(`${res.status} ${t.slice(0, 200)}`);
    }
    const ct = res.headers.get("content-type") || "";
    if (ct.includes("application/json")) return res.json();
    return res.text();
  }

  function preset() {
    return PRESETS.find((p) => p.id === state.selectedMoodId) ?? PRESETS[0];
  }

  function spectrumHex(hue) {
    const [r, g, b] = hsvToRgb(hue, 0.92, 0.98);
    return rgbToHex(r, g, b);
  }

  function rgbToHex(r, g, b) {
    const x = (n) =>
      Math.max(0, Math.min(255, Math.round(n * 255)))
        .toString(16)
        .padStart(2, "0");
    return `#${x(r)}${x(g)}${x(b)}`.toUpperCase();
  }

  function hsvToRgb(h, s, v) {
    const i = Math.floor(h * 6);
    const f = h * 6 - i;
    const p = v * (1 - s);
    const q = v * (1 - f * s);
    const t = v * (1 - (1 - f) * s);
    let r = 0,
      g = 0,
      b = 0;
    switch (i % 6) {
      case 0:
        r = v;
        g = t;
        b = p;
        break;
      case 1:
        r = q;
        g = v;
        b = p;
        break;
      case 2:
        r = p;
        g = v;
        b = t;
        break;
      case 3:
        r = p;
        g = q;
        b = v;
        break;
      case 4:
        r = t;
        g = p;
        b = v;
        break;
      case 5:
        r = v;
        g = p;
        b = q;
        break;
    }
    return [r, g, b];
  }

  function hexToHue(hex) {
    const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
    if (!m) return 0;
    const n = parseInt(m[1], 16);
    const r = ((n >> 16) & 0xff) / 255;
    const g = ((n >> 8) & 0xff) / 255;
    const b = (n & 0xff) / 255;
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const d = max - min;
    if (d < 1e-6) return 0;
    let hh = 0;
    if (max === r) hh = ((g - b) / d + (g < b ? 6 : 0)) / 6;
    else if (max === g) hh = ((b - r) / d + 2) / 6;
    else hh = ((r - g) / d + 4) / 6;
    return hh;
  }

  function previewHex() {
    if (state.customColorEnabled) return spectrumHex(state.spectrumHue);
    return preset().hex;
  }

  function headlineTitle() {
    if (state.customColorEnabled) {
      const t = $("customMoodName").value.trim();
      if (t) return t;
    }
    if (state.lastLabel && state.lastLabel !== "—") return state.lastLabel;
    return preset().title;
  }

  function colorHexForAPI() {
    if (!state.customColorEnabled) return null;
    return spectrumHex(state.spectrumHue);
  }

  function moodLabelForAPI() {
    if (!state.customColorEnabled) return null;
    const t = $("customMoodName").value.trim();
    return t ? t.slice(0, 48) : null;
  }

  /** Committed label for explain-mood only (after Done). */
  function moodLabelForInsightAPI() {
    if (!state.customColorEnabled) return null;
    const t = state.customMoodInsightCommitted.trim();
    return t ? t.slice(0, 48) : null;
  }

  function labelLikelyGibberish(label) {
    const raw = String(label || "").trim();
    if (!raw) return false;
    const letters = [...raw].filter((ch) => /[A-Za-z]/.test(ch)).join("");
    if (letters.length < 2) return true;
    const low = letters.toLowerCase();
    if (low.length >= 2 && new Set(low).size === 1) return true;
    const vowels = [...low].filter((c) => "aeiouy".includes(c)).length;
    if (low.length >= 4 && vowels === 0) return true;
    if (low.length >= 5 && vowels / low.length < 0.12) return true;
    const alphaChars = [...raw].filter((ch) => /[A-Za-z]/.test(ch));
    if (alphaChars.length >= 5) {
      const up = alphaChars.map((c) => c === c.toUpperCase() && c !== c.toLowerCase());
      let transitions = 0;
      for (let i = 0; i < up.length - 1; i++) {
        if (up[i] !== up[i + 1]) transitions += 1;
      }
      if (transitions >= Math.max(3, Math.floor(up.length * 0.4))) return true;
    }
    return false;
  }

  function updatePreviewUI() {
    const hex = previewHex();
    const on = state.lampPowerOn;
    const el = $("lampGlow");
    el.classList.toggle("off", !on);
    const c1 = hexToRgb(hex);
    const c2 = mix(c1, { r: 0.6, g: 0.4, b: 0.9 }, 0.35);
    el.style.background = `radial-gradient(circle at 30% 30%, ${rgba(c1, on ? 0.95 : 0.25)}, ${rgba(
      c2,
      on ? 0.35 : 0.12
    )})`;
    $("headline").textContent = headlineTitle();
    $("brightnessVal").textContent = String(Math.round(state.lampBrightness));
    $("brightness").value = String(state.lampBrightness);
    $("blinkBpmDisplay").textContent = String(Math.round(state.blinkBpm));
    $("powerLabel").textContent = on ? "On" : "Off";
    $("powerBtn").classList.toggle("on", on);
  }

  function hexToRgb(hex) {
    const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
    if (!m) return { r: 1, g: 0.4, b: 0.7 };
    const n = parseInt(m[1], 16);
    return {
      r: ((n >> 16) & 0xff) / 255,
      g: ((n >> 8) & 0xff) / 255,
      b: (n & 0xff) / 255,
    };
  }

  function rgba(c, a) {
    return `rgba(${Math.round(c.r * 255)},${Math.round(c.g * 255)},${Math.round(c.b * 255)},${a})`;
  }

  function mix(a, b, t) {
    return {
      r: a.r * (1 - t) + b.r * t,
      g: a.g * (1 - t) + b.g * t,
      b: a.b * (1 - t) + b.b * t,
    };
  }

  function applyAnalyzeResponse(resp) {
    state.lastMood = resp.mood ?? state.selectedMoodId;
    state.lastLabel = resp.label ?? resp.mood ?? "—";
    state.lastReason = resp.reason ?? "";
    state.insightClassifierReason = resp.reason ?? null;
    state.lastAnalyzeSource = resp.source ?? "";
    if (resp.brightness != null) state.lampBrightness = resp.brightness;
    if (resp.powerOn != null) state.lampPowerOn = !!resp.powerOn;
    if (resp.blinkEnabled != null) state.blinkEnabled = !!resp.blinkEnabled;
    if (resp.blinkBpm != null) state.blinkBpm = clamp(resp.blinkBpm, 30, 220);
    $("blinkEnabled").checked = state.blinkEnabled;
    $("blinkBpmDraft").value = String(Math.round(state.blinkBpm));
    syncBlinkPanel();
    updatePreviewUI();
    $("updatedAt").textContent = new Date().toLocaleTimeString(undefined, {
      hour: "numeric",
      minute: "2-digit",
      second: "2-digit",
    });
  }

  function clamp(x, lo, hi) {
    return Math.min(hi, Math.max(lo, x));
  }

  function clearInsightHeartContextForManualSelection() {
    state.insightRestingBpm = null;
    state.insightRecentBpms = null;
    state.insightClassifierReason = null;
  }

  function moodChangedForInsight(prev, next) {
    const known = ["calm", "stressed", "happy", "sad"];
    const p = String(prev || "")
      .trim()
      .toLowerCase();
    const n = String(next || "")
      .trim()
      .toLowerCase();
    if (!known.includes(p) || p === "—") return known.includes(n);
    return p !== n;
  }

  async function refreshMoodInsight(fallbackMood, customMoodName = null) {
    state.insightGen += 1;
    const token = state.insightGen;
    const moodKey =
      state.lastMood && state.lastMood !== "—" && ["calm", "stressed", "happy", "sad"].includes(state.lastMood)
        ? state.lastMood
        : fallbackMood;

    const d = new Date();
    const localDate = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(
      d.getDate()
    ).padStart(2, "0")}`;

    const body = {
      deviceId: deviceId(),
      mood: moodKey,
      localDate,
      timeZoneId: Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
      restingBpm: state.insightRestingBpm,
      recentBpms: state.insightRecentBpms,
      classifierReason: state.insightClassifierReason,
      analyzeSource: state.lastAnalyzeSource || null,
      customMoodName: customMoodName || null,
    };

    try {
      const data = await apiFetch("/v1/cardiac/explain-mood", {
        method: "POST",
        body: JSON.stringify(body),
      });
      if (token !== state.insightGen) return;
      state.moodInsight = data.caption || "";
      $("moodInsight").textContent = state.moodInsight;
    } catch {
      if (token !== state.insightGen) return;
      state.moodInsight = localFallbackInsight(moodKey, customMoodName);
      $("moodInsight").textContent = state.moodInsight;
    }
  }

  function localFallbackInsight(mood, customName) {
    const c = customName && String(customName).trim();
    if (c) {
      const clip = c.slice(0, 48);
      if (labelLikelyGibberish(clip)) {
        return "I'm sure you feel this way for a certain reason—no need to put it into perfect words.";
      }
      const low = c.toLowerCase();
      if (/scar|fear|afraid|panic/.test(low)) {
        return `For «${clip}»: sudden noise, shadows, or a racing mind can spike that feeling—the lamp keeps the edge soft.`;
      }
      if (/anger|rage|mad|furious/.test(low)) {
        return `For «${clip}»: friction, unfair surprises, or tight deadlines often fan the heat—breathe with the glow.`;
      }
      if (/peace|calm|relax/.test(low)) {
        return `For «${clip}»: slow breathing, a cozy corner, or winding down fits this light.`;
      }
      const m = String(mood || "calm").toLowerCase();
      const tail =
        {
          stressed: "overload, deadlines, or a nervous system on high alert",
          happy: "good news, bright company, or plain relief today",
          sad: "a heavy hour, goodbyes, or quiet tiredness",
        }[m] || "needing less noise, a slower breath, or a softer corner";
      return `If «${clip}» fits you, this ${m} light can echo ${tail}—take what resonates.`;
    }
    const map = {
      stressed:
        "Stressed tones can mirror a hectic stretch — weather, deadlines, or just too much coffee.",
      happy:
        "Happy glow fits sunny moods — weekend plans, good news, or the simple lift of a brighter hour.",
      sad: "Softer blues nod to quiet moments — rainy windows, long evenings, or needing gentler light.",
    };
    return (
      map[mood] ??
      "Calm gold suits slow breathing — cozy indoors, a pause between tasks, or a softer slice of the day."
    );
  }

  async function pushManualLamp() {
    state.manualGen = (state.manualGen || 0) + 1;
    const token = state.manualGen;
    const mood = state.selectedMoodId;
    const bpmClamped = clamp(state.blinkBpm, 30, 220);

    $("syncSpinner").style.display = "inline-block";
    $("lastError").textContent = "";

    try {
      const resp = await apiFetch("/v1/cardiac/manual", {
        method: "POST",
        body: JSON.stringify({
          deviceId: deviceId(),
          mood,
          brightness: Math.round(state.lampBrightness),
          color: colorHexForAPI(),
          powerOn: state.lampPowerOn,
          blinkEnabled: state.blinkEnabled,
          blinkBpm: bpmClamped,
          moodLabel: moodLabelForAPI(),
        }),
      });
      if (token !== state.manualGen) return;
      const prevMood = state.lastMood;
      state.insightRestingBpm = null;
      state.insightRecentBpms = null;
      applyAnalyzeResponse(resp);
      if (moodChangedForInsight(prevMood, resp.mood)) {
        await refreshMoodInsight(mood, moodLabelForInsightAPI());
      }
    } catch (e) {
      if (token !== state.manualGen) return;
      $("lastError").textContent = String(e.message || e);
    } finally {
      $("syncSpinner").style.display = "none";
    }
  }

  function scheduleLampSyncDebounced() {
    if (state.debounceTimer) clearTimeout(state.debounceTimer);
    state.debounceTimer = setTimeout(() => {
      state.debounceTimer = null;
      pushManualLamp();
    }, DEBOUNCE_MS);
  }

  function syncLampImmediate() {
    if (state.debounceTimer) {
      clearTimeout(state.debounceTimer);
      state.debounceTimer = null;
    }
    pushManualLamp();
  }

  function syncBlinkPanel() {
    const en = state.blinkEnabled;
    const p = $("blinkPanel");
    p.style.opacity = en ? "1" : "0.45";
    p.style.pointerEvents = en ? "auto" : "none";
    $("applyBpmBtn").disabled = !en;
    $("blinkBpmDraft").disabled = !en;
  }

  function buildMoodGrid() {
    const grid = $("moodGrid");
    grid.innerHTML = "";
    for (const pr of PRESETS) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "mood-tile" + (pr.id === state.selectedMoodId ? " selected" : "");
      btn.innerHTML = `
        <div class="tile-head">
          <span class="tile-icon">${pr.icon}</span>
          ${pr.id === state.selectedMoodId ? '<span class="check">✓</span>' : "<span></span>"}
        </div>
        <h3>${pr.title}</h3>
      `;
      btn.addEventListener("click", () => {
        clearInsightHeartContextForManualSelection();
        state.selectedMoodId = pr.id;
        if (state.customColorEnabled) {
          state.spectrumHue = hexToHue(pr.hex);
          $("spectrumHue").value = String(state.spectrumHue);
        }
        buildMoodGrid();
        syncLampImmediate();
      });
      grid.appendChild(btn);
    }
  }

  function applyTheme(mode) {
    const root = document.documentElement;
    if (mode === "light") {
      root.setAttribute("data-theme", "light");
    } else if (mode === "dark") {
      root.setAttribute("data-theme", "dark");
    } else {
      root.removeAttribute("data-theme");
    }
  }

  /** ---------- Init ---------- */
  loadSettings();
  state.customMoodInsightCommitted = localStorage.getItem(STORAGE.moodInsightCommitted) ?? "";

  $("baseUrl").addEventListener("change", saveSettings);
  $("apiKey").addEventListener("change", saveSettings);
  $("deviceId").addEventListener("change", saveSettings);

  $("powerBtn").addEventListener("click", () => {
    state.lampPowerOn = !state.lampPowerOn;
    updatePreviewUI();
    syncLampImmediate();
  });

  $("brightness").addEventListener("input", (e) => {
    state.lampBrightness = Number(e.target.value);
    updatePreviewUI();
    scheduleLampSyncDebounced();
  });

  $("blinkEnabled").addEventListener("change", (e) => {
    state.blinkEnabled = e.target.checked;
    syncBlinkPanel();
    syncLampImmediate();
  });

  $("applyBpmBtn").addEventListener("click", () => {
    $("lastError").textContent = "";
    const raw = $("blinkBpmDraft").value.trim();
    if (!raw) {
      $("blinkBpmDraft").value = String(Math.round(state.blinkBpm));
      return;
    }
    const v = parseFloat(raw.replace(",", "."));
    if (!Number.isFinite(v)) {
      $("lastError").textContent = "Enter a valid number for BPM.";
      return;
    }
    state.blinkBpm = clamp(v, 30, 220);
    $("blinkBpmDraft").value = String(Math.round(state.blinkBpm));
    updatePreviewUI();
    syncLampImmediate();
  });

  $("customColorEnabled").addEventListener("change", (e) => {
    state.customColorEnabled = e.target.checked;
    $("customPanel").style.display = e.target.checked ? "block" : "none";
    if (e.target.checked) {
      state.spectrumHue = hexToHue(preset().hex);
      $("spectrumHue").value = String(state.spectrumHue);
    }
    updatePreviewUI();
    syncLampImmediate();
    refreshMoodInsight(state.selectedMoodId, moodLabelForInsightAPI());
  });

  $("spectrumHue").addEventListener("input", (e) => {
    state.spectrumHue = Number(e.target.value);
    updatePreviewUI();
    scheduleLampSyncDebounced();
  });

  $("customMoodName").addEventListener("input", () => {
    updatePreviewUI();
    scheduleLampSyncDebounced();
  });

  $("customMoodDone").addEventListener("click", () => {
    const t = $("customMoodName").value.trim().slice(0, 48);
    state.customMoodInsightCommitted = t;
    localStorage.setItem(STORAGE.moodInsightCommitted, t);
    $("customMoodName").blur();
    refreshMoodInsight(state.selectedMoodId, moodLabelForInsightAPI());
  });

  $("fixedAppearance").addEventListener("change", (e) => {
    localStorage.setItem(STORAGE.fixedAppearance, e.target.checked ? "1" : "0");
    $("appearancePick").style.display = e.target.checked ? "block" : "none";
    if (!e.target.checked) {
      localStorage.removeItem(STORAGE.appearance);
      applyTheme("system");
      document.querySelectorAll(".segmented button[data-appearance]").forEach((b) => b.classList.remove("active"));
    }
  });

  document.querySelectorAll(".segmented button[data-appearance]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const m = btn.dataset.appearance;
      localStorage.setItem(STORAGE.appearance, m);
      document.querySelectorAll(".segmented button[data-appearance]").forEach((b) => {
        b.classList.toggle("active", b === btn);
      });
      applyTheme(m);
    });
  });

  $("runAnalyzeBtn").addEventListener("click", async () => {
    $("lastError").textContent = "";
    const restingRaw = $("restingBpm").value.trim();
    const restingBpm = restingRaw ? clamp(parseFloat(restingRaw), 30, 120) : null;

    const parts = $("bpmSamples").value
      .split(/[\s,]+/)
      .map((s) => s.trim())
      .filter(Boolean);
    const bpms = parts.map((p) => parseFloat(p)).filter((n) => Number.isFinite(n));
    if (bpms.length < 1) {
      $("lastError").textContent = "Enter at least one BPM sample.";
      return;
    }

    $("syncSpinner").style.display = "inline-block";
    try {
      const now = new Date().toISOString();
      const samples = bpms.map((bpm) => ({ t: now, bpm: clamp(bpm, 30, 230) }));
      const resp = await apiFetch("/v1/cardiac/analyze", {
        method: "POST",
        body: JSON.stringify({
          deviceId: deviceId(),
          restingBpm,
          samples,
          timeZoneId: Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
        }),
      });
      state.insightRestingBpm = restingBpm;
      state.insightRecentBpms = bpms;
      const prevMood = state.lastMood;
      state.selectedMoodId = resp.mood;
      applyAnalyzeResponse(resp);
      buildMoodGrid();
      if (moodChangedForInsight(prevMood, resp.mood)) {
        await refreshMoodInsight(resp.mood, null);
      }
    } catch (e) {
      $("lastError").textContent = String(e.message || e);
    } finally {
      $("syncSpinner").style.display = "none";
    }
  });

  state.spectrumHue = hexToHue(preset().hex);
  $("spectrumHue").value = String(state.spectrumHue);
  $("blinkBpmDraft").value = "72";

  buildMoodGrid();
  syncBlinkPanel();
  updatePreviewUI();

  syncLampImmediate();
  const draftInit = $("customMoodName").value.trim();
  if (!state.customMoodInsightCommitted && draftInit) {
    state.customMoodInsightCommitted = draftInit.slice(0, 48);
    localStorage.setItem(STORAGE.moodInsightCommitted, state.customMoodInsightCommitted);
  }
  refreshMoodInsight(state.selectedMoodId, moodLabelForInsightAPI());
})();
