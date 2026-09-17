/* Mars Focus — web (PWA) port of the iOS app. Same wine theme, same session
   engine semantics: blocklists, sessions (now / later / recurring, locked
   mode), calendar with auto-applied slots, history heatmap, optional AI coach.
   Browsers can't block other apps, so "blocking" here is tracked, not
   enforced — parity with the iOS app running without Screen Time. */

"use strict";

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

const $ = (sel) => document.querySelector(sel);
const uid = () => (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2));

const startOfDay = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate());
const addDays = (d, n) => { const c = new Date(d); c.setDate(c.getDate() + n); return startOfDay(c); };
/// Wall-clock time `minutes` after midnight on the given day (DST-safe: uses
/// calendar components, not elapsed-time arithmetic).
const timeAtMinutes = (dayStart, minutes) =>
  new Date(dayStart.getFullYear(), dayStart.getMonth(), dayStart.getDate(),
           Math.floor(minutes / 60), minutes % 60);
const sameDay = (a, b) => startOfDay(a).getTime() === startOfDay(b).getTime();
const dayKey = (d) => { const s = startOfDay(d); return `${s.getFullYear()}-${s.getMonth() + 1}-${s.getDate()}`; };

const fmtClock = (d) => d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
const fmtDuration = (seconds) => {
  const totalMinutes = Math.round(seconds / 60);
  const h = Math.floor(totalMinutes / 60), m = totalMinutes % 60;
  if (h > 0 && m > 0) return `${h}h ${m}m`;
  if (h > 0) return `${h}h`;
  return `${m}m`;
};
const fmtCountdown = (seconds) => {
  const t = Math.max(0, Math.round(seconds));
  const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
  const pad = (n) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
};
const fmtMinutesOfDay = (minutes) => fmtClock(timeAtMinutes(startOfDay(new Date()), minutes));
const esc = (s) => String(s).replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// ---------------------------------------------------------------------------
// App catalog (mirrors the iOS AppCatalog)
// ---------------------------------------------------------------------------

const APP_CATALOG = [
  { id: "instagram", name: "Instagram", icon: "📷" },
  { id: "tiktok", name: "TikTok", icon: "🎵" },
  { id: "youtube", name: "YouTube", icon: "▶️" },
  { id: "x", name: "X (Twitter)", icon: "🔤" },
  { id: "facebook", name: "Facebook", icon: "👥" },
  { id: "reddit", name: "Reddit", icon: "💬" },
  { id: "snapchat", name: "Snapchat", icon: "⚡️" },
  { id: "messages", name: "Messages", icon: "💬" },
  { id: "whatsapp", name: "WhatsApp", icon: "📞" },
  { id: "discord", name: "Discord", icon: "🎧" },
  { id: "netflix", name: "Netflix", icon: "📺" },
  { id: "twitch", name: "Twitch", icon: "🎥" },
  { id: "games", name: "Games", icon: "🎮" },
  { id: "news", name: "News", icon: "📰" },
  { id: "shopping", name: "Shopping", icon: "🛒" },
  { id: "email", name: "Email", icon: "✉️" },
];
const catalogApp = (id) => APP_CATALOG.find((a) => a.id === id);

// Keyword → domains expansion (mirrors the iOS KeywordCatalog).
const KEYWORD_CATALOG = {
  streaming: ["netflix.com", "hulu.com", "disneyplus.com", "max.com", "primevideo.com",
              "twitch.tv", "youtube.com", "peacocktv.com", "paramountplus.com", "crunchyroll.com"],
  anime: ["crunchyroll.com", "funimation.com", "hianime.to", "9animetv.to", "gogoanime.by",
          "animepahe.ru", "zoro.to", "aniwave.to", "myanimelist.net", "anilist.co"],
  social: ["facebook.com", "instagram.com", "tiktok.com", "x.com", "twitter.com",
           "reddit.com", "snapchat.com", "threads.net", "pinterest.com"],
  video: ["youtube.com", "vimeo.com", "dailymotion.com", "twitch.tv", "tiktok.com"],
  news: ["cnn.com", "bbc.com", "nytimes.com", "foxnews.com", "reuters.com",
         "news.google.com", "theguardian.com"],
  shopping: ["amazon.com", "ebay.com", "aliexpress.com", "temu.com", "shein.com", "etsy.com"],
  games: ["store.steampowered.com", "epicgames.com", "roblox.com", "miniclip.com",
          "itch.io", "twitch.tv", "ign.com"],
  gambling: ["bet365.com", "draftkings.com", "fanduel.com", "pokerstars.com", "stake.com"],
  sports: ["espn.com", "sports.yahoo.com", "bleacherreport.com", "nba.com", "nfl.com"],
};
function keywordDomains(keyword) {
  const needle = keyword.toLowerCase().trim();
  if (!needle) return [];
  const result = new Set(KEYWORD_CATALOG[needle] || []);
  for (const domains of Object.values(KEYWORD_CATALOG)) {
    for (const domain of domains) if (domain.includes(needle)) result.add(domain);
  }
  return [...result].sort();
}
const keywordExpand = (keywords) => {
  const all = new Set();
  for (const k of keywords || []) for (const d of keywordDomains(k)) all.add(d);
  return [...all].sort();
};

// ---------------------------------------------------------------------------
// Persistent state
// ---------------------------------------------------------------------------

const STORAGE = { blocklists: "tom-blocklists", sessions: "tom-sessions", coach: "tom-coach" };

function loadJSON(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return fallback;
    const value = JSON.parse(raw);
    return value ?? fallback;
  } catch {
    // Parity with iOS: set unreadable state aside instead of overwriting it.
    try { localStorage.setItem(key + "-corrupt", localStorage.getItem(key)); } catch {}
    return fallback;
  }
}
function defaultBlocklists() {
  return [
    { id: uid(), name: "Social Media",
      appIDs: ["instagram", "tiktok", "x", "facebook", "reddit", "snapchat"],
      websites: ["instagram.com", "tiktok.com", "x.com", "facebook.com", "reddit.com"],
      keywords: ["social"] },
    { id: uid(), name: "Video & Streaming",
      appIDs: ["youtube", "netflix", "twitch"],
      websites: ["youtube.com", "netflix.com", "twitch.tv"],
      keywords: ["streaming"] },
  ];
}

function normalizeSessions(value) {
  const state = Object.assign({ active: null, scheduled: [], rules: [], history: [], triggered: {}, lastUsed: [] }, value);
  for (const key of ["scheduled", "rules", "history", "lastUsed"]) {
    if (!Array.isArray(state[key])) state[key] = [];
  }
  if (!state.triggered || typeof state.triggered !== "object" || Array.isArray(state.triggered)) state.triggered = {};
  if (state.active && (!state.active.startedAt || !state.active.endsAt)) state.active = null;
  return state;
}

// Keep legacy records for recovery. Remove the old credential copy only after
// the combined document is saved, so clearing a key cannot leave it behind.
// The combined document makes each save atomic across lists and sessions.
const STATE_KEY = "tom-state-v1";
const withStorageLock = createStorageLock("track-on-me-storage");
let blocklists = [];
const S = normalizeSessions({});
const coachCfg = { provider: "gemini", keys: {} };
let coachMessages = [];
let coachLoading = false;
let coachError = null;
let coachDraft = "";
let persistenceError = null;

function reloadState() {
  const stored = loadJSON(STATE_KEY, null);
  const lists = stored ? stored.blocklists : loadJSON(STORAGE.blocklists, null);
  blocklists = Array.isArray(lists) ? lists : defaultBlocklists();
  for (const b of blocklists) if (!Array.isArray(b.keywords)) b.keywords = [];
  Object.assign(S, normalizeSessions(stored ? stored.sessions : loadJSON(STORAGE.sessions, {})));
  const config = (stored ? stored.coach : loadJSON(STORAGE.coach, null)) || {};
  coachCfg.provider = config.provider === "claude" ? "claude" : "gemini";
  coachCfg.keys = config.keys && typeof config.keys === "object" && !Array.isArray(config.keys) ? config.keys : {};
}

function encodedState() {
  return JSON.stringify({ blocklists, sessions: S, coach: coachCfg });
}

function mutateState(action) {
  return withStorageLock(() => {
    reloadState();
    const before = localStorage.getItem(STATE_KEY);
    const result = action();
    const after = encodedState();
    if (after !== before) localStorage.setItem(STATE_KEY, after);
    if (localStorage.getItem(STORAGE.coach) !== null) localStorage.removeItem(STORAGE.coach);
    persistenceError = null;
    return result ?? true;
  }).catch((error) => {
    // A failed save must not leave a successful-looking unsaved session in UI.
    reloadState();
    const message = "Could not save app data: " + String(error.message || error);
    if (message !== persistenceError) alert(message);
    persistenceError = message;
    render();
    return false;
  });
}

const listsByIDs = (ids) => ids.map((id) => blocklists.find((b) => b.id === id)).filter(Boolean);
const listSummary = (b) => {
  const parts = [];
  if (b.appIDs.length) parts.push(`${b.appIDs.length} app${b.appIDs.length === 1 ? "" : "s"}`);
  if (b.websites.length) parts.push(`${b.websites.length} website${b.websites.length === 1 ? "" : "s"}`);
  const kw = (b.keywords || []).length;
  if (kw) parts.push(`${kw} keyword${kw === 1 ? "" : "s"}`);
  return parts.length ? parts.join(" · ") : "Empty";
};

// ---------------------------------------------------------------------------
// Schedule-rule occurrence math (ported from Models.swift)
// ---------------------------------------------------------------------------

const crossesMidnight = (rule) => rule.endMinutes <= rule.startMinutes;

function occurrenceStartingOn(rule, dayStart) {
  const start = timeAtMinutes(dayStart, rule.startMinutes);
  const endDay = crossesMidnight(rule) ? addDays(dayStart, 1) : dayStart;
  const end = timeAtMinutes(endDay, rule.endMinutes);
  return end > start ? { start, end } : null;
}

function occurrenceContaining(rule, date) {
  for (const offset of [0, -1]) {
    const dayStart = addDays(startOfDay(date), offset);
    if (!rule.weekdays.includes(dayStart.getDay() + 1)) continue;
    const occ = occurrenceStartingOn(rule, dayStart);
    if (occ && date >= occ.start && date < occ.end) return occ;
  }
  return null;
}

function nextOccurrence(rule, after) {
  if (!rule.isEnabled || !rule.weekdays.length) return null;
  for (let offset = -1; offset <= 7; offset++) {
    const dayStart = addDays(startOfDay(after), offset);
    if (!rule.weekdays.includes(dayStart.getDay() + 1)) continue;
    const occ = occurrenceStartingOn(rule, dayStart);
    if (occ && occ.end > after) return occ;
  }
  return null;
}

const occurrenceKey = (rule, start) => `${rule.id}|${Math.floor(start.getTime() / 1000)}`;

function daysSummary(rule) {
  if (rule.weekdays.length === 7) return "Every day";
  const symbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  return [1, 2, 3, 4, 5, 6, 7].filter((d) => rule.weekdays.includes(d)).map((d) => symbols[d - 1]).join(" ");
}
const timeSummary = (rule) =>
  `${fmtMinutesOfDay(rule.startMinutes)} – ${fmtMinutesOfDay(rule.endMinutes)}${crossesMidnight(rule) ? " (+1 day)" : ""}`;

// ---------------------------------------------------------------------------
// Session engine (ported from SessionStore.swift)
// ---------------------------------------------------------------------------

const D = (iso) => new Date(iso); // hydrate stored ISO strings
const scheduledEnd = (sch) => new Date(D(sch.startAt).getTime() + sch.minutes * 60000);

function recordSession(session, endedAt, endedEarly) {
  S.history.push({
    id: uid(),
    startedAt: session.startedAt,
    endedAt: endedAt.toISOString(),
    plannedMinutes: Math.round((D(session.endsAt) - D(session.startedAt)) / 60000),
    blocklistNames: session.blocklistNames,
    scheduleName: session.scheduleName || null,
    endedEarly,
  });
}

function activate({ blocklistIDs, startedAt, endsAt, isLocked, scheduleName }) {
  const lists = listsByIDs(blocklistIDs);
  S.active = {
    id: uid(),
    startedAt: startedAt.toISOString(),
    endsAt: endsAt.toISOString(),
    blocklistIDs,
    blocklistNames: lists.map((b) => b.name),
    isLocked,
    scheduleName: scheduleName || null,
  };
  notifyAtEnd(endsAt);
}

function notifyAtEnd(_endsAt) {
  // tick() posts the completion notification itself (single source of truth);
  // this only makes sure permission has been asked for by then.
  if (typeof Notification !== "undefined" && Notification.permission === "default") {
    Notification.requestPermission();
  }
}

/// Android Chrome forbids the page-context Notification constructor — it
/// throws "Illegal constructor" — so prefer the service-worker path and never
/// let a notification failure abort the session engine.
function postNotification(title, body) {
  if (typeof Notification === "undefined" || Notification.permission !== "granted") return;
  const viaSW = () => navigator.serviceWorker?.ready
    .then((reg) => reg.showNotification(title, { body, icon: "icon-192.png" }))
    .catch(() => {});
  try {
    if (navigator.serviceWorker?.controller) viaSW();
    else new Notification(title, { body, icon: "icon-192.png" });
  } catch {
    viaSW();
  }
}

let lastRenderDay = dayKey(new Date());

function tick() {
  return mutateState(() => {
    const now = new Date();
    let dirty = false;

    // Re-render when the calendar day rolls over so an idle tab never keeps
    // showing yesterday as "today" (parity with the iOS onDayChange helper).
    if (dayKey(now) !== lastRenderDay) {
      lastRenderDay = dayKey(now);
      render();
    }

    if (S.active && D(S.active.endsAt) <= now) {
      recordSession(S.active, D(S.active.endsAt), false);
      S.active = null;
      Soundscape.stop();
      dirty = true;
      postNotification("Session complete", "You stayed focused. Nice work.");
    }

    // Drop queued sessions whose whole window passed, or whose lists were all deleted.
    const before = S.scheduled.length;
    S.scheduled = S.scheduled.filter((sch) =>
      scheduledEnd(sch) > now && !(D(sch.startAt) <= now && listsByIDs(sch.blocklistIDs).length === 0));
    if (S.scheduled.length !== before) dirty = true;

    // Start the earliest due queued session. Focus counts from "now" — never
    // backdated into unobserved time.
    if (!S.active) {
      const due = S.scheduled.filter((sch) => D(sch.startAt) <= now)
        .sort((a, b) => D(a.startAt) - D(b.startAt))[0];
      if (due) {
        S.scheduled = S.scheduled.filter((sch) => sch.id !== due.id);
        activate({ blocklistIDs: due.blocklistIDs, startedAt: now, endsAt: scheduledEnd(due),
                   isLocked: due.isLocked, scheduleName: due.name });
        dirty = true;
      }
    }

    // Recurring rules whose window contains "now".
    if (!S.active) {
      for (const rule of S.rules) {
        if (!rule.isEnabled) continue;
        if (listsByIDs(rule.blocklistIDs).length === 0) continue; // dormant
        const occ = occurrenceContaining(rule, now);
        if (!occ) continue;
        const key = occurrenceKey(rule, occ.start);
        if (S.triggered[key]) continue;
        S.triggered[key] = occ.end.toISOString();
        const cutoff = now.getTime() - 48 * 3600 * 1000;
        for (const k of Object.keys(S.triggered)) {
          if (D(S.triggered[k]).getTime() < cutoff) delete S.triggered[k];
        }
        activate({ blocklistIDs: rule.blocklistIDs, startedAt: now, endsAt: occ.end, isLocked: rule.isLocked, scheduleName: rule.name });
        dirty = true;
        break;
      }
    }

    if (dirty) { render(); }
    else if (S.active && currentTab === "focus") renderActiveCountdown(now);
    updateTitle(now);
  });
}

function updateTitle(now) {
  document.title = S.active
    ? `${fmtCountdown((D(S.active.endsAt) - now) / 1000)} · Mars Focus`
    : "Mars Focus";
}

function startSession(blocklistIDs, minutes, isLocked) {
  return mutateState(() => {
    blocklistIDs = listsByIDs(blocklistIDs).map((b) => b.id);
    if (S.active || minutes <= 0 || !blocklistIDs.length) return false;
    const now = new Date();
    S.lastUsed = blocklistIDs;
    activate({ blocklistIDs, startedAt: now, endsAt: new Date(now.getTime() + minutes * 60000), isLocked });
    render();
  });
}

function scheduleSession(startAt, minutes, blocklistIDs, isLocked) {
  return mutateState(() => {
    blocklistIDs = listsByIDs(blocklistIDs).map((b) => b.id);
    if (minutes <= 0 || !blocklistIDs.length) return false;
    S.lastUsed = blocklistIDs;
    S.scheduled.push({ id: uid(), startAt: startAt.toISOString(), minutes, blocklistIDs, isLocked });
    S.scheduled.sort((a, b) => D(a.startAt) - D(b.startAt));
    render();
  });
}

function endActiveEarly() {
  const activeID = S.active?.id;
  return mutateState(() => {
    if (!S.active || S.active.id !== activeID || S.active.isLocked) return false;
    recordSession(S.active, new Date(), true);
    S.active = null;
    Soundscape.stop();
    render();
  });
}

/// Pomodoro: round 1 starts now; later rounds are named queued sessions, so
/// breaks are simply the unblocked gaps between them.
function startPomodoro(blocklistIDs, workMinutes, breakMinutes, rounds, isLocked) {
  return mutateState(() => {
    blocklistIDs = listsByIDs(blocklistIDs).map((b) => b.id);
    if (S.active || workMinutes <= 0 || rounds < 1 || !blocklistIDs.length) return false;
    const now = new Date();
    S.lastUsed = blocklistIDs;
    activate({
      blocklistIDs, startedAt: now,
      endsAt: new Date(now.getTime() + workMinutes * 60000),
      isLocked, scheduleName: rounds > 1 ? `Pomodoro 1 of ${rounds}` : "Pomodoro",
    });
    const cycle = (workMinutes + breakMinutes) * 60000;
    for (let round = 1; round < rounds; round++) {
      S.scheduled.push({
        id: uid(), startAt: new Date(now.getTime() + cycle * round).toISOString(),
        minutes: workMinutes, blocklistIDs, isLocked,
        name: `Pomodoro ${round + 1} of ${rounds}`,
      });
    }
    S.scheduled.sort((a, b) => D(a.startAt) - D(b.startAt));
    render();
  });
}

// Ambient focus sounds via WebAudio — same synthesized white/rain/deep noise
// as the iOS SoundscapePlayer; stops automatically when the session ends.
const Soundscape = {
  current: "Off",
  ctx: null,
  node: null,
  select(mode) {
    this.current = mode;
    if (mode === "Off") { this.stop(); return; }
    if (!this.ctx) {
      this.ctx = new (window.AudioContext || window.webkitAudioContext)();
      const node = this.ctx.createScriptProcessor(4096, 0, 1);
      let seed = 0x9e3779b9, lowPass = 0, brown = 0;
      node.onaudioprocess = (e) => {
        const out = e.outputBuffer.getChannelData(0);
        const mode = this.current;
        for (let i = 0; i < out.length; i++) {
          seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
          const white = ((seed >>> 8) & 0xffff) / 0xffff * 2 - 1;
          if (mode === "White") out[i] = white * 0.12;
          else if (mode === "Rain") { lowPass += 0.06 * (white - lowPass); out[i] = lowPass * 0.55 + white * 0.02; }
          else if (mode === "Deep") { brown = (brown + 0.02 * white) * 0.998; out[i] = brown * 1.1; }
          else out[i] = 0;
        }
      };
      node.connect(this.ctx.destination);
      this.node = node;
    }
    this.ctx.resume();
    renderActiveSoundChips();
  },
  stop() {
    this.current = "Off";
    if (this.node) { this.node.disconnect(); this.node = null; }
    if (this.ctx) { this.ctx.close().catch(() => {}); this.ctx = null; }
    renderActiveSoundChips();
  },
};

function renderActiveSoundChips() {
  document.querySelectorAll("[data-sound]").forEach((chip) =>
    chip.classList.toggle("on", chip.dataset.sound === Soundscape.current));
}

function extendActive(minutes) {
  const activeID = S.active?.id;
  return mutateState(() => {
    if (!S.active || S.active.id !== activeID) return false;
    S.active.endsAt = new Date(D(S.active.endsAt).getTime() + minutes * 60000).toISOString();
    render();
  });
}

const lockedBlocklistIDs = () =>
  S.active && S.active.isLocked ? new Set(S.active.blocklistIDs) : new Set();

function nextUpcoming(after) {
  const candidates = S.scheduled.map((sch) => ({ title: sch.name || "Scheduled session", start: D(sch.startAt), end: scheduledEnd(sch) }));
  for (const rule of S.rules) {
    if (listsByIDs(rule.blocklistIDs).length === 0) continue;
    // Skip past windows that already fired — they can never start again.
    let occ = nextOccurrence(rule, after);
    let hops = 0;
    while (occ && S.triggered[occurrenceKey(rule, occ.start)] && hops++ < 8) {
      occ = nextOccurrence(rule, occ.end);
    }
    if (!occ) continue;
    candidates.push({ title: rule.name, start: occ.start, end: occ.end });
  }
  candidates.sort((a, b) => a.start - b.start);
  return candidates[0] || null;
}

// --- Stats (ported from SessionStore) --------------------------------------

function dayMinutes() {
  const minutes = {};
  const addSpan = (start, end) => {
    let cursor = start;
    while (cursor < end) {
      const dayStart = startOfDay(cursor);
      const boundary = addDays(dayStart, 1);
      const segmentEnd = boundary < end ? boundary : end;
      if (segmentEnd <= cursor) break;
      minutes[dayKey(dayStart)] = (minutes[dayKey(dayStart)] || 0) + (segmentEnd - cursor) / 60000;
      cursor = segmentEnd;
    }
  };
  for (const r of S.history) addSpan(D(r.startedAt), D(r.endedAt));
  if (S.active) {
    const now = new Date();
    const end = D(S.active.endsAt) < now ? D(S.active.endsAt) : now;
    addSpan(D(S.active.startedAt), end);
  }
  return minutes;
}
const heatLevel = (m) => (m <= 0 ? 0 : Math.max(1, Math.min(4, Math.ceil(m / 30))));

function currentStreak(minutes) {
  let day = startOfDay(new Date());
  if (!minutes[dayKey(day)]) day = addDays(day, -1);
  let streak = 0;
  while (minutes[dayKey(day)]) { streak++; day = addDays(day, -1); }
  return streak;
}

function bestStreak(minutes) {
  const days = new Set(Object.keys(minutes).filter((k) => minutes[k] > 0));
  let best = 0;
  for (const key of days) {
    const [y, m, d] = key.split("-").map(Number);
    const day = new Date(y, m - 1, d);
    if (days.has(dayKey(addDays(day, -1)))) continue;
    let length = 1, cursor = day;
    while (days.has(dayKey(addDays(cursor, 1)))) { length++; cursor = addDays(cursor, 1); }
    best = Math.max(best, length);
  }
  return best;
}

function totalFocusSeconds() {
  let total = S.history.reduce((sum, r) => sum + Math.max(0, (D(r.endedAt) - D(r.startedAt)) / 1000), 0);
  if (S.active) {
    const now = new Date();
    const end = D(S.active.endsAt) < now ? D(S.active.endsAt) : now;
    total += Math.max(0, (end - D(S.active.startedAt)) / 1000);
  }
  return total;
}

function sessionsOn(day) {
  const dayStart = startOfDay(day), nextDay = addDays(dayStart, 1);
  return S.history
    .filter((r) => D(r.startedAt) < nextDay && D(r.endedAt) > dayStart)
    .sort((a, b) => D(a.startedAt) - D(b.startedAt));
}

function plannedSlots(day) {
  const dayStart = startOfDay(day);
  if (dayStart < startOfDay(new Date())) return []; // history speaks for past days
  const nextDay = addDays(dayStart, 1);
  const slots = S.scheduled
    .filter((sch) => D(sch.startAt) < nextDay && scheduledEnd(sch) > dayStart)
    .map((sch) => ({ title: sch.name || "Scheduled session", start: D(sch.startAt), end: scheduledEnd(sch) }));
  for (const rule of S.rules) {
    if (!rule.isEnabled || listsByIDs(rule.blocklistIDs).length === 0) continue;
    for (const offset of [0, -1]) { // -1 catches overnight tails
      const start = addDays(dayStart, offset);
      if (!rule.weekdays.includes(start.getDay() + 1)) continue;
      const occ = occurrenceStartingOn(rule, start);
      if (occ && occ.start < nextDay && occ.end > dayStart) slots.push({ title: rule.name, ...occ });
    }
  }
  return slots.sort((a, b) => a.start - b.start);
}

const sessionTitle = (r) =>
  r.scheduleName || (r.blocklistNames.length ? r.blocklistNames.join(", ") : "Focus session");

// ---------------------------------------------------------------------------
// Coach (Gemini / Anthropic) — mirrors CoachService.swift
// ---------------------------------------------------------------------------

const COACH_SYSTEM = `You are the focus coach inside "Mars Focus", an app where the user blocks distracting apps and websites during focus sessions. You receive the user's real focus statistics with every message. Be a warm, practical coach: point at concrete patterns in the data, celebrate streaks, suggest specific schedule tweaks, and keep answers under 150 words. Never invent data that isn't in the stats.`;

function coachContext() {
  const minutes = dayMinutes();
  const lines = [];
  lines.push(`Current streak: ${currentStreak(minutes)} days; best streak: ${bestStreak(minutes)} days.`);
  const early = S.history.filter((r) => r.endedEarly).length;
  lines.push(`Sessions completed: ${S.history.length - early}; ended early: ${early}.`);
  lines.push(`Total focus time: ${fmtDuration(totalFocusSeconds())}.`);
  if (S.active) lines.push(`A session is running right now, ending at ${fmtClock(D(S.active.endsAt))}.`);
  for (const rule of S.rules) {
    lines.push(`Schedule "${rule.name}": ${daysSummary(rule)}, ${timeSummary(rule)} (${rule.isEnabled ? "enabled" : "disabled"}${rule.isLocked ? ", locked" : ""}).`);
  }
  if (blocklists.length) lines.push(`Blocklists: ${blocklists.map((b) => b.name).join(", ")}.`);
  const recent = [];
  for (let i = 0; i < 14; i++) {
    const day = addDays(startOfDay(new Date()), -i);
    recent.push(`${day.toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" })}: ${Math.round(minutes[dayKey(day)] || 0)} min`);
  }
  lines.push(`Focus minutes per day, most recent first:\n${recent.join("\n")}`);
  return lines.join("\n");
}

const coachKey = () => (coachCfg.keys[coachCfg.provider] || "").trim();

async function coachSend(text) {
  const trimmed = text.trim();
  if (!trimmed || coachLoading) return trimmed || null;
  if (!coachKey()) { coachError = "Add an API key in Settings first."; renderCoach(); return trimmed; }
  coachMessages.push({ role: "user", text: trimmed });
  coachLoading = true;
  coachError = null;
  renderCoach();
  try {
    const system = `${COACH_SYSTEM}\n\nThe user's current stats:\n${coachContext()}`;
    const reply = coachCfg.provider === "claude" ? await askClaude(system) : await askGemini(system);
    coachMessages.push({ role: "coach", text: reply });
    coachLoading = false;
    renderCoach();
    return null;
  } catch (err) {
    coachError = String(err.message || err).slice(0, 300);
    // Remove the unanswered question so a retry doesn't duplicate it.
    if (coachMessages[coachMessages.length - 1]?.role === "user") coachMessages.pop();
    coachLoading = false;
    renderCoach();
    return trimmed;
  }
}

async function askGemini(system) {
  const res = await fetch(
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent",
    {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": coachKey() },
      body: JSON.stringify({
        system_instruction: { parts: [{ text: system }] },
        contents: coachMessages.map((m) => ({
          role: m.role === "user" ? "user" : "model",
          parts: [{ text: m.text }],
        })),
      }),
    });
  if (!res.ok) throw new Error(`Gemini returned ${res.status}. Check your key.`);
  const json = await res.json();
  const text = (json.candidates?.[0]?.content?.parts || []).filter((p) => !p.thought).map((p) => p.text || "").join("");
  if (!text) throw new Error("Gemini sent an unreadable response.");
  return text;
}

async function askClaude(system) {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": coachKey(),
      "anthropic-version": "2023-06-01",
      "anthropic-dangerous-direct-browser-access": "true", // required for CORS from a browser
    },
    body: JSON.stringify({
      model: "claude-haiku-4-5",
      max_tokens: 1024,
      system,
      messages: coachMessages.map((m) => ({ role: m.role === "user" ? "user" : "assistant", content: m.text })),
    }),
  });
  if (!res.ok) throw new Error(`Claude returned ${res.status}. Check your key.`);
  const json = await res.json();
  const text = (json.content || []).filter((b) => b.type === "text").map((b) => b.text).join("");
  if (!text) throw new Error("Claude sent an unreadable response.");
  return text;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

let currentTab = "focus";
let calMonth = startOfDay(new Date()); calMonth.setDate(1);

function switchTab(tab) {
  currentTab = tab;
  document.querySelectorAll("#tabbar button").forEach((b) => b.classList.toggle("on", b.dataset.tab === tab));
  render();
}

let startSheetSync = null; // lets tick()-driven renders refresh an open Start sheet

function render() {
  const main = $("#main");
  switch (currentTab) {
    case "focus": main.innerHTML = renderFocus(); wireFocus(); break;
    case "blocklists": main.innerHTML = renderBlocklists(); wireBlocklists(); break;
    case "calendar": main.innerHTML = renderCalendar(); wireCalendar(); break;
    case "history": {
      main.innerHTML = renderHistory();
      const card = main.querySelector(".heatmap-card");
      if (card) card.scrollLeft = card.scrollWidth; // current week rightmost
      break;
    }
    case "coach": {
      main.innerHTML = renderCoachShell();
      const draft = $("#coach-draft");
      if (draft) draft.value = coachDraft;
      renderCoach();
      wireCoach();
      break;
    }
  }
  startSheetSync?.();
  updateTitle(new Date());
}

// --- Focus tab --------------------------------------------------------------

const QUICKS = [
  { minutes: 15, title: "15 min", icon: "🐇", bg: "var(--rose)" },
  { minutes: 30, title: "30 min", icon: "⏱", bg: "var(--wine)" },
  { minutes: 60, title: "1 hour", icon: "⌛️", bg: "var(--wine-deep)" },
  { minutes: 120, title: "2 hours", icon: "⛰", bg: "", outlined: true },
];

function quickIDs() {
  const existing = new Set(blocklists.map((b) => b.id));
  const last = (S.lastUsed || []).filter((id) => existing.has(id));
  return last.length ? last : blocklists.map((b) => b.id);
}

function renderFocus() {
  let html = `<div class="page-header"><h1 class="page-title">Mars Focus</h1>
    <div class="toolbar"><button class="icon-btn" id="btn-settings" title="Settings">⚙︎</button></div></div>`;
  if (S.active) return html + renderActive();

  const up = nextUpcoming(new Date());
  if (up) {
    html += `<button class="row upnext" id="btn-upnext">
      <span class="icon-circle">🕐</span>
      <span class="row-body"><span class="row-title">Up next · ${esc(up.title)}</span>
      <span class="row-sub">${up.start.toLocaleDateString([], { weekday: "short" })} ${fmtClock(up.start)} – ${fmtClock(up.end)}</span></span>
    </button>`;
  }
  const sub = `${quickIDs().length} blocklist${quickIDs().length === 1 ? "" : "s"}`;
  html += `<div class="quick-grid">` + QUICKS.map((q, i) =>
    `<button class="quick-card ${q.outlined ? "outlined" : ""}" data-quick="${q.minutes}" style="background:${q.bg}">
      <span class="qc-top"><span>${q.icon}</span><span>▶</span></span>
      <span class="qc-title">${q.title}</span><span class="qc-sub">${esc(sub)}</span>
    </button>`).join("") + `</div>`;
  html += `<button class="btn-primary" id="btn-custom">🛡 Custom Session</button>
    <div style="height:10px"></div>
    <button class="btn-outline" id="btn-pomodoro">⏱ Pomodoro</button>`;
  return html;
}

function renderActive() {
  const a = S.active;
  const lists = listsByIDs(a.blocklistIDs);
  const rows = lists.length
    ? lists.map((b) => `<div class="row"><span class="icon-circle">✋</span>
        <span class="row-body"><span class="row-title">${esc(b.name)}</span>
        <span class="row-sub">${esc(listSummary(b))}</span></span></div>`).join("")
    : a.blocklistNames.map((n) => `<div class="row"><span class="icon-circle">✋</span>
        <span class="row-body"><span class="row-title">${esc(n)}</span></span></div>`).join("");
  return `<div class="active-wrap">
    <div class="active-title">${esc(a.scheduleName || "You're in a focus session")}</div>
    ${a.isLocked ? '<div class="locked-chip">🔒 Locked</div>' : ""}
    <div class="ring-wrap">
      <svg width="230" height="230" viewBox="0 0 230 230">
        <circle cx="115" cy="115" r="108" fill="none" stroke="var(--blush)" stroke-width="14"/>
        <circle id="ring" cx="115" cy="115" r="108" fill="none" stroke="var(--wine)" stroke-width="14"
          stroke-linecap="round" stroke-dasharray="678.6" stroke-dashoffset="0"/>
      </svg>
      <div class="ring-time"><div class="big" id="countdown">--:--</div>
      <div class="caption">Ends at ${fmtClock(D(a.endsAt))}</div></div>
    </div>
    <div style="display:flex;gap:8px;justify-content:center;align-items:center;margin:2px 0 6px">
      <span class="mono-wine">🔊</span>
      ${["Off", "Rain", "White", "Deep"].map((s) =>
        `<button class="app-chip ${Soundscape.current === s ? "on" : ""}" data-sound="${s}"
          style="flex:none;border-radius:999px;padding:6px 14px">${s}</button>`).join("")}
    </div>
    <div class="blocked-list"><h2 class="section">Blocking</h2>${rows}</div>
    <div class="controls">
      <button class="btn-outline" id="btn-extend">＋ Add 15 min</button>
      ${a.isLocked
        ? `<div class="btn-quiet" style="color:var(--secondary)"><span class="mono-wine">🔒</span> Locked until ${fmtClock(D(a.endsAt))}</div>`
        : `<button class="btn-primary" id="btn-end">End Session</button>`}
    </div>
  </div>`;
}

function renderActiveCountdown(now) {
  const a = S.active;
  if (!a) return;
  const total = (D(a.endsAt) - D(a.startedAt)) / 1000;
  const remaining = Math.max(0, (D(a.endsAt) - now) / 1000);
  const el = $("#countdown");
  if (el) el.textContent = fmtCountdown(remaining);
  const ring = $("#ring");
  if (ring && total > 0) {
    const frac = Math.min(1, Math.max(0, remaining / total));
    ring.setAttribute("stroke-dashoffset", String(678.6 * (1 - frac)));
  }
}

function wireFocus() {
  $("#btn-settings")?.addEventListener("click", openSettings);
  $("#btn-custom")?.addEventListener("click", () => openStartSheet());
  $("#btn-pomodoro")?.addEventListener("click", openPomodoroSheet);
  $("#btn-upnext")?.addEventListener("click", () => switchTab("calendar"));
  document.querySelectorAll("[data-sound]").forEach((chip) =>
    chip.addEventListener("click", () => Soundscape.select(chip.dataset.sound)));
  document.querySelectorAll("[data-quick]").forEach((btn) =>
    btn.addEventListener("click", () => {
      const ids = quickIDs();
      if (!ids.length) { openStartSheet(); return; }
      startSession(ids, Number(btn.dataset.quick), false);
    }));
  $("#btn-extend")?.addEventListener("click", () => {
    if (S.active?.isLocked &&
        !confirm("Add 15 minutes to this locked session? You won't be able to end it any sooner.")) return;
    extendActive(15);
  });
  $("#btn-end")?.addEventListener("click", () => {
    if (confirm("End this session early?")) endActiveEarly();
  });
  if (S.active) renderActiveCountdown(new Date());
}

// --- Start sheet ------------------------------------------------------------

function openStartSheet(presetStart) {
  const dlg = $("#dlg-start");
  const selected = new Set(quickIDs());
  const toLocalInput = (d) => {
    const p = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
  };
  // Clamp calendar presets so a late-evening "next full hour" can't be in the past.
  const preset = presetStart
    ? new Date(Math.max(presetStart.getTime(), Date.now() + 60000))
    : new Date(Date.now() + 3600000);
  dlg.innerHTML = `
    <div class="dialog-bar"><button id="ss-cancel">Cancel</button><span class="title">New Session</span><span style="width:52px"></span></div>
    <div class="dialog-body">
      ${S.active ? '<div class="error-card">A session is already running — you can still schedule one for later.</div>' : ""}
      <h2 class="section">Block</h2>
      <div id="ss-lists">${blocklists.length ? blocklists.map((b) => `
        <button class="row ss-list" data-id="${b.id}">
          <span class="icon-circle ${selected.has(b.id) ? "" : "outlined"}">✋</span>
          <span class="row-body"><span class="row-title">${esc(b.name)}</span>
          <span class="row-sub">${esc(listSummary(b))}</span></span>
          <span class="check" style="color:var(--wine)">${selected.has(b.id) ? "●" : "○"}</span>
        </button>`).join("") : '<div class="empty-note">No blocklists yet — create one in the Blocklists tab first.</div>'}
      </div>
      <h2 class="section">For</h2>
      <div class="field-row">
        <select id="ss-hours">${Array.from({ length: 25 }, (_, h) => `<option value="${h}">${h} h</option>`).join("")}</select>
        <select id="ss-mins">${Array.from({ length: 12 }, (_, i) => `<option value="${i * 5}" ${i * 5 === 30 ? "selected" : ""}>${i * 5} m</option>`).join("")}</select>
      </div>
      <h2 class="section">When</h2>
      <div class="segmented"><button id="ss-now" class="${presetStart ? "" : "on"}">Now</button><button id="ss-later" class="${presetStart ? "on" : ""}">Later</button></div>
      <input type="datetime-local" id="ss-start" value="${toLocalInput(preset)}" class="${presetStart ? "" : "hidden"}">
      <h2 class="section">Options</h2>
      <label class="toggle-row"><span class="mono-wine">🔒</span>
        <span class="row-body"><span class="row-title">Locked mode</span>
        <span class="row-sub">You won't be able to end the session early.</span></span>
        <span class="switch"><input type="checkbox" id="ss-locked"><span class="knob"></span></span>
      </label>
      <div style="height:14px"></div>
      <button class="btn-primary" id="ss-go">Start Session</button>
    </div>`;
  let mode = presetStart ? "later" : "now";
  let saving = false;
  const refresh = () => {
    $("#ss-now").classList.toggle("on", mode === "now");
    $("#ss-later").classList.toggle("on", mode === "later");
    $("#ss-start").classList.toggle("hidden", mode === "now");
    const minutes = Number($("#ss-hours").value) * 60 + Number($("#ss-mins").value);
    $("#ss-go").textContent = mode === "now" ? "Start Session" : "Schedule Session";
    $("#ss-go").disabled = saving || !selected.size || minutes <= 0 || (mode === "now" && !!S.active);
  };
  dlg.querySelectorAll(".ss-list").forEach((row) => row.addEventListener("click", () => {
    const id = row.dataset.id;
    selected.has(id) ? selected.delete(id) : selected.add(id);
    row.querySelector(".check").textContent = selected.has(id) ? "●" : "○";
    row.querySelector(".icon-circle").classList.toggle("outlined", !selected.has(id));
    refresh();
  }));
  $("#ss-now").addEventListener("click", () => { mode = "now"; refresh(); });
  $("#ss-later").addEventListener("click", () => { mode = "later"; refresh(); });
  $("#ss-hours").addEventListener("change", refresh);
  $("#ss-mins").addEventListener("change", refresh);
  $("#ss-cancel").addEventListener("click", () => dlg.close());
  // A schedule can auto-start while this sheet is open; keep the Start button
  // honest instead of letting it silently no-op.
  startSheetSync = refresh;
  dlg.addEventListener("close", () => { startSheetSync = null; }, { once: true });
  $("#ss-go").addEventListener("click", async () => {
    if (saving) return;
    const minutes = Number($("#ss-hours").value) * 60 + Number($("#ss-mins").value);
    const ids = blocklists.map((b) => b.id).filter((id) => selected.has(id));
    const startAt = mode === "later" ? new Date($("#ss-start").value) : null;
    if (startAt && (isNaN(startAt) || startAt <= new Date())) { alert("Pick a start time in the future."); return; }
    const button = $("#ss-go");
    saving = true;
    refresh();
    try {
      const saved = startAt
        ? await scheduleSession(startAt, minutes, ids, $("#ss-locked").checked)
        : await startSession(ids, minutes, $("#ss-locked").checked);
      if (saved && $("#ss-go") === button) dlg.close();
    } finally {
      saving = false;
      if ($("#ss-go") === button) refresh();
    }
  });
  refresh();
  dlg.showModal();
}

// --- Pomodoro sheet ---------------------------------------------------------

function openPomodoroSheet() {
  const dlg = $("#dlg-pomodoro");
  const selected = new Set(quickIDs());
  let work = 25, brk = 5, rounds = 4;
  const chipRow = (id, choices, value, suffix) => `
    <div style="display:flex;gap:8px">${choices.map((c) => `
      <button class="app-chip ${c === value ? "on" : ""}" data-group="${id}" data-value="${c}"
        style="flex:1;justify-content:center">${c} ${suffix}</button>`).join("")}</div>`;
  const paint = () => {
    dlg.innerHTML = `
      <div class="dialog-bar"><button id="po-cancel">Cancel</button><span class="title">Pomodoro</span><span style="width:52px"></span></div>
      <div class="dialog-body">
        ${S.active ? '<div class="error-card">A session is already running — finish it before starting a Pomodoro.</div>' : ""}
        <h2 class="section">Work</h2>${chipRow("work", [15, 25, 45, 50], work, "min")}
        <h2 class="section">Break</h2>${chipRow("brk", [5, 10, 15], brk, "min")}
        <h2 class="section">Rounds</h2>${chipRow("rounds", [2, 3, 4, 6], rounds, "×")}
        <h2 class="section">Block</h2>
        ${blocklists.length ? blocklists.map((b) => `
          <button class="row po-list" data-id="${b.id}">
            <span class="icon-circle ${selected.has(b.id) ? "" : "outlined"}">✋</span>
            <span class="row-body"><span class="row-title">${esc(b.name)}</span>
            <span class="row-sub">${esc(listSummary(b))}</span></span>
            <span class="check" style="color:var(--wine)">${selected.has(b.id) ? "●" : "○"}</span>
          </button>`).join("") : '<div class="empty-note">No blocklists yet — create one in the Blocklists tab first.</div>'}
        <h2 class="section">Options</h2>
        <label class="toggle-row"><span class="mono-wine">🔒</span>
          <span class="row-body"><span class="row-title">Locked mode</span>
          <span class="row-sub">Work rounds can't be ended early.</span></span>
          <span class="switch"><input type="checkbox" id="po-locked"><span class="knob"></span></span>
        </label>
        <p class="caption" style="margin-top:10px">Breaks are unblocked. Total: ${fmtDuration((rounds * work + (rounds - 1) * brk) * 60)}. Remaining rounds appear under Upcoming on the Calendar.</p>
        <div style="height:10px"></div>
        <button class="btn-primary" id="po-go" ${!selected.size || S.active ? "disabled" : ""}>Start Pomodoro</button>
      </div>`;
    $("#po-cancel").addEventListener("click", () => dlg.close());
    dlg.querySelectorAll("[data-group]").forEach((chip) => chip.addEventListener("click", () => {
      const value = Number(chip.dataset.value);
      const locked = $("#po-locked").checked;
      if (chip.dataset.group === "work") work = value;
      else if (chip.dataset.group === "brk") brk = value;
      else rounds = value;
      paint();
      $("#po-locked").checked = locked;
    }));
    dlg.querySelectorAll(".po-list").forEach((row) => row.addEventListener("click", () => {
      const id = row.dataset.id;
      selected.has(id) ? selected.delete(id) : selected.add(id);
      row.querySelector(".check").textContent = selected.has(id) ? "●" : "○";
      row.querySelector(".icon-circle").classList.toggle("outlined", !selected.has(id));
      $("#po-go").disabled = !selected.size || !!S.active;
    }));
    $("#po-go").addEventListener("click", async () => {
      const ids = blocklists.map((b) => b.id).filter((id) => selected.has(id));
      const saved = await startPomodoro(ids, work, brk, rounds, $("#po-locked").checked);
      if (saved) dlg.close();
    });
  };
  paint();
  dlg.showModal();
}

// --- Blocklists tab ---------------------------------------------------------

function renderBlocklists() {
  const locked = lockedBlocklistIDs();
  let html = `<div class="page-header"><h1 class="page-title">Blocklists</h1>
    <div class="toolbar"><button class="icon-btn" id="bl-add">＋</button></div></div>`;
  if (!blocklists.length) {
    html += '<div class="empty-note">No blocklists yet — tap + to create your first one.</div>';
  } else {
    html += blocklists.map((b) => `
      <div class="row">
        <button style="display:flex;align-items:center;gap:12px;flex:1;min-width:0;text-align:left" class="bl-open" data-id="${b.id}">
          <span class="icon-circle">✋</span>
          <span class="row-body"><span class="row-title">${esc(b.name)}
            ${locked.has(b.id) ? '<span class="lock-badge">🔒</span>' : ""}</span>
          <span class="row-sub">${esc(listSummary(b))}</span></span>
        </button>
        ${locked.has(b.id) ? "" : `<button class="x-btn bl-del" data-id="${b.id}">ⓧ</button>`}
      </div>`).join("");
    html += '<p class="caption" style="margin-top:8px">Blocklists define what you\'re avoiding while a focus session runs. In the browser, sessions are tracked — apps can\'t be force-closed. The iPhone app can shield real apps with Screen Time.</p>';
  }
  return html;
}

function wireBlocklists() {
  $("#bl-add").addEventListener("click", () => openBlocklistEditor(null));
  document.querySelectorAll(".bl-open").forEach((btn) => btn.addEventListener("click", () => {
    if (lockedBlocklistIDs().has(btn.dataset.id)) {
      alert("This blocklist is locked: it's part of a locked focus session and can be edited once the session ends.");
      return;
    }
    openBlocklistEditor(blocklists.find((b) => b.id === btn.dataset.id));
  }));
  document.querySelectorAll(".bl-del").forEach((btn) => btn.addEventListener("click", () => {
    const b = blocklists.find((x) => x.id === btn.dataset.id);
    if (b && confirm(`Delete "${b.name}"?`)) {
      mutateState(() => {
        if (lockedBlocklistIDs().has(b.id)) return false;
        blocklists = blocklists.filter((x) => x.id !== b.id);
        render();
      });
    }
  }));
}

function openBlocklistEditor(existing) {
  const dlg = $("#dlg-blocklist");
  const apps = new Set(existing ? existing.appIDs : []);
  let sites = existing ? [...existing.websites] : [];
  let kws = existing ? [...(existing.keywords || [])] : [];
  // Tracked separately so repaints (chip toggles, site edits) never revert
  // a half-typed name.
  let nameValue = existing ? existing.name : "";
  let saving = false;
  let saveButton;
  const paint = () => {
    dlg.innerHTML = `
      <div class="dialog-bar"><button id="be-cancel">Cancel</button>
        <span class="title">${existing ? "Edit Blocklist" : "New Blocklist"}</span>
        <button id="be-save" ${saving ? "disabled" : ""}><b>Save</b></button></div>
      <div class="dialog-body">
        <h2 class="section">Name</h2>
        <input type="text" id="be-name" placeholder="e.g. Social Media" value="${esc(nameValue)}">
        <h2 class="section">Apps</h2>
        <div class="app-grid">${APP_CATALOG.map((a) => `
          <button class="app-chip ${apps.has(a.id) ? "on" : ""}" data-app="${a.id}">
            <span>${a.icon}</span><span>${esc(a.name)}</span>${apps.has(a.id) ? '<span class="check">✓</span>' : ""}
          </button>`).join("")}</div>
        <h2 class="section">Websites</h2>
        <div class="field-row">
          <input type="url" id="be-site" placeholder="example.com">
          <button class="icon-btn" id="be-site-add" style="font-size:28px">⊕</button>
        </div>
        <div id="be-sites">${sites.map((s) => `
          <div class="row"><span class="icon-circle outlined">🌐</span>
          <span class="row-body"><span class="row-title">${esc(s)}</span></span>
          <button class="x-btn be-site-del" data-site="${esc(s)}">ⓧ</button></div>`).join("")}</div>
        <h2 class="section">Keywords</h2>
        <p class="caption">Block whole categories at once — a keyword expands to every matching site we know.</p>
        <div style="display:flex;gap:8px;overflow-x:auto;padding:8px 0">${Object.keys(KEYWORD_CATALOG).sort().map((k) => `
          <button class="app-chip be-kw-suggest ${kws.includes(k) ? "on" : ""}" data-kw="${k}"
            style="flex:none;border-radius:999px">${k}</button>`).join("")}</div>
        <div class="field-row">
          <input type="text" id="be-kw" placeholder="e.g. anime">
          <button class="icon-btn" id="be-kw-add" style="font-size:28px">⊕</button>
        </div>
        <div>${kws.map((k) => {
          const n = keywordDomains(k).length;
          return `<div class="row"><span class="icon-circle outlined" style="font-size:11px">abc</span>
            <span class="row-body"><span class="row-title">${esc(k)}</span>
            <span class="row-sub">${n ? `Blocks ${n} site${n === 1 ? "" : "s"}` : "No known sites match yet"}</span></span>
            <button class="x-btn be-kw-del" data-kw="${esc(k)}">ⓧ</button></div>`;
        }).join("")}</div>
      </div>`;
    $("#be-cancel").addEventListener("click", () => dlg.close());
    $("#be-name").addEventListener("input", (e) => { nameValue = e.target.value; });
    dlg.querySelectorAll("[data-app]").forEach((chip) => chip.addEventListener("click", () => {
      const id = chip.dataset.app;
      apps.has(id) ? apps.delete(id) : apps.add(id);
      paint();
    }));
    const addSite = () => {
      let site = $("#be-site").value.trim().toLowerCase();
      for (const prefix of ["https://", "http://", "www."]) if (site.startsWith(prefix)) site = site.slice(prefix.length);
      site = site.split("/")[0];
      if (!site.includes(".") || sites.includes(site)) return;
      sites.push(site);
      paint();
      $("#be-site").focus();
    };
    $("#be-site-add").addEventListener("click", addSite);
    $("#be-site").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); addSite(); } });
    dlg.querySelectorAll(".be-site-del").forEach((btn) => btn.addEventListener("click", () => {
      sites = sites.filter((s) => s !== btn.dataset.site);
      paint();
    }));
    dlg.querySelectorAll(".be-kw-suggest").forEach((chip) => chip.addEventListener("click", () => {
      const k = chip.dataset.kw;
      kws = kws.includes(k) ? kws.filter((x) => x !== k) : [...kws, k];
      paint();
    }));
    const addKeyword = () => {
      const k = $("#be-kw").value.toLowerCase().trim();
      if (!k || kws.includes(k)) return;
      kws.push(k);
      paint();
      $("#be-kw").focus();
    };
    $("#be-kw-add").addEventListener("click", addKeyword);
    $("#be-kw").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); addKeyword(); } });
    dlg.querySelectorAll(".be-kw-del").forEach((btn) => btn.addEventListener("click", () => {
      kws = kws.filter((k) => k !== btn.dataset.kw);
      paint();
    }));
    saveButton = $("#be-save");
    saveButton.addEventListener("click", async () => {
      if (saving) return;
      nameValue = $("#be-name").value;
      const name = nameValue.trim();
      if (!name) { alert("Give the blocklist a name."); return; }
      const orderedApps = APP_CATALOG.map((a) => a.id).filter((id) => apps.has(id));
      const values = { name, appIDs: orderedApps, websites: [...sites], keywords: [...kws] };
      const button = $("#be-save");
      saving = true;
      button.disabled = true;
      try {
        const saved = await mutateState(() => {
          if (existing) {
            const current = blocklists.find((b) => b.id === existing.id);
            if (!current || lockedBlocklistIDs().has(existing.id)) {
              alert("This blocklist was deleted or locked in another window. Reopen it to edit.");
              return false;
            }
            Object.assign(current, values);
          } else {
            blocklists.push({ id: uid(), ...values });
          }
        });
        if (saved && $("#be-save") === saveButton) { dlg.close(); render(); }
      } finally {
        saving = false;
        saveButton.disabled = false;
      }
    });
  };
  paint();
  dlg.showModal();
}

// --- Calendar tab -----------------------------------------------------------

function renderCalendar() {
  const today = startOfDay(new Date());
  const first = new Date(calMonth.getFullYear(), calMonth.getMonth(), 1);
  const daysInMonth = new Date(calMonth.getFullYear(), calMonth.getMonth() + 1, 0).getDate();
  const leading = first.getDay();
  const minutes = dayMinutes();

  let cells = "";
  for (let i = 0; i < leading; i++) cells += "<div></div>";
  for (let d = 1; d <= daysInMonth; d++) {
    const day = new Date(calMonth.getFullYear(), calMonth.getMonth(), d);
    const focus = (minutes[dayKey(day)] || 0) > 0;
    const slot = plannedSlots(day).length > 0;
    cells += `<button class="cal-cell ${sameDay(day, today) ? "today" : ""}" data-day="${day.getTime()}">
      <span class="num">${d}</span>
      <span class="cal-dots">${focus ? '<span class="dot"></span>' : ""}${slot ? '<span class="dot ring"></span>' : ""}</span>
    </button>`;
  }

  const monthName = calMonth.toLocaleDateString([], { month: "long", year: "numeric" });
  let html = `<div class="page-header"><h1 class="page-title">Calendar</h1>
    <div class="toolbar"><button class="icon-btn" id="rule-add">＋</button></div></div>
    <div class="cal-header">
      <button class="cal-nav" id="cal-prev">‹</button>
      <span class="month">${monthName}</span>
      <button class="cal-nav" id="cal-next">›</button>
    </div>
    <div class="cal-weekdays">${["S", "M", "T", "W", "T", "F", "S"].map((s) => `<div>${s}</div>`).join("")}</div>
    <div class="cal-grid">${cells}</div>
    <div class="cal-legend"><span><span class="dot"></span>Focused</span><span><span class="dot ring"></span>Planned block</span></div>`;

  if (S.scheduled.length) {
    html += '<h2 class="section">Upcoming</h2>' + S.scheduled.map((sch) => `
      <div class="row"><span class="icon-circle">🕐</span>
        <span class="row-body"><span class="row-title">
          ${sch.name ? esc(sch.name) + " · " : ""}${D(sch.startAt).toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" })} at ${fmtClock(D(sch.startAt))}
          ${sch.isLocked ? '<span class="lock-badge">🔒</span>' : ""}</span>
        <span class="row-sub">${fmtDuration(sch.minutes * 60)} · ${esc(listsByIDs(sch.blocklistIDs).map((b) => b.name).join(", ") || "No blocklists")}</span></span>
        <button class="x-btn sch-del" data-id="${sch.id}">ⓧ</button></div>`).join("");
  }

  html += '<h2 class="section">Recurring</h2>';
  if (!S.rules.length) {
    html += '<div class="empty-note">No recurring schedules yet — tap + to block distractions at the same time every day.</div>';
  } else {
    html += S.rules.map((rule) => `
      <div class="row">
        <button style="display:flex;align-items:center;gap:12px;flex:1;min-width:0;text-align:left" class="rule-open" data-id="${rule.id}">
          <span class="icon-circle ${rule.isEnabled ? "" : "outlined"}">↻</span>
          <span class="row-body"><span class="row-title" style="${rule.isEnabled ? "" : "color:var(--secondary)"}">${esc(rule.name)}
            ${rule.isLocked ? '<span class="lock-badge">🔒</span>' : ""}</span>
          <span class="row-sub">${daysSummary(rule)} · ${timeSummary(rule)}</span>
          <span class="row-sub">${esc(listsByIDs(rule.blocklistIDs).map((b) => b.name).join(", ") || "No blocklists")}</span></span>
        </button>
        <label class="switch"><input type="checkbox" class="rule-toggle" data-id="${rule.id}" ${rule.isEnabled ? "checked" : ""}><span class="knob"></span></label>
      </div>`).join("");
  }
  return html;
}

function wireCalendar() {
  $("#cal-prev").addEventListener("click", () => { calMonth = new Date(calMonth.getFullYear(), calMonth.getMonth() - 1, 1); render(); });
  $("#cal-next").addEventListener("click", () => { calMonth = new Date(calMonth.getFullYear(), calMonth.getMonth() + 1, 1); render(); });
  $("#rule-add").addEventListener("click", () => openRuleEditor(null));
  document.querySelectorAll(".cal-cell").forEach((cell) =>
    cell.addEventListener("click", () => openDaySheet(new Date(Number(cell.dataset.day)))));
  document.querySelectorAll(".sch-del").forEach((btn) => btn.addEventListener("click", () => {
    if (confirm("Cancel this scheduled session?")) {
      const id = btn.dataset.id;
      mutateState(() => {
        S.scheduled = S.scheduled.filter((sch) => sch.id !== id);
        render();
      });
    }
  }));
  document.querySelectorAll(".rule-open").forEach((btn) => btn.addEventListener("click", () =>
    openRuleEditor(S.rules.find((r) => r.id === btn.dataset.id))));
  document.querySelectorAll(".rule-toggle").forEach((toggle) => toggle.addEventListener("change", () => {
    const id = toggle.dataset.id, enabled = toggle.checked;
    mutateState(() => {
      const rule = S.rules.find((r) => r.id === id);
      if (rule) rule.isEnabled = enabled;
      render();
    }).then(() => tick());
  }));
}

function openDaySheet(day) {
  const dlg = $("#dlg-day");
  const isPast = startOfDay(day) < startOfDay(new Date());
  const isToday = sameDay(day, new Date());
  const slots = plannedSlots(day);
  const records = sessionsOn(day);
  const title = day.toLocaleDateString([], { weekday: "long", month: "short", day: "numeric" });

  let body = "";
  if (!isPast) {
    body += '<h2 class="section">Blocked Time</h2>';
    body += slots.length ? slots.map((s) => `
      <div class="row"><span class="icon-circle">🕐</span>
        <span class="row-body"><span class="row-title">${esc(s.title)}</span>
        <span class="row-sub">${fmtClock(s.start)} – ${fmtClock(s.end)}</span></span></div>`).join("")
      : '<div class="caption">No blocks planned yet.</div>';
  }
  body += '<h2 class="section">Focus Sessions</h2>';
  if (isToday && S.active) {
    const a = S.active;
    const elapsed = Math.max(0, (Math.min(Date.now(), D(a.endsAt).getTime()) - D(a.startedAt).getTime()) / 1000);
    body += `<div class="row"><span class="icon-circle">⏱</span>
      <span class="row-body"><span class="row-title">${esc(a.scheduleName || "Focus session")}</span>
      <span class="row-sub">In progress · ends ${fmtClock(D(a.endsAt))}</span></span>
      <span class="row-trail">${fmtDuration(elapsed)}</span></div>`;
  }
  if (!records.length && !(isToday && S.active)) {
    body += '<div class="caption">Nothing logged on this day.</div>';
  } else {
    body += records.map((r) => `
      <div class="row"><span class="icon-circle ${r.endedEarly ? "outlined" : ""}">${r.endedEarly ? "⃠" : "✓"}</span>
        <span class="row-body"><span class="row-title">${esc(sessionTitle(r))}</span>
        <span class="row-sub">${fmtClock(D(r.startedAt))}</span></span>
        <span class="row-trail">${fmtDuration((D(r.endedAt) - D(r.startedAt)) / 1000)}
          ${r.endedEarly ? '<span class="caption">ended early</span>' : ""}</span></div>`).join("");
  }
  if (!isPast) body += '<div style="height:10px"></div><button class="btn-primary" id="day-plan">＋ Block Time on This Day</button>';

  dlg.innerHTML = `<div class="dialog-bar"><span style="width:52px"></span><span class="title">${title}</span>
    <button id="day-done"><b>Done</b></button></div><div class="dialog-body">${body}</div>`;
  $("#day-done").addEventListener("click", () => dlg.close());
  $("#day-plan")?.addEventListener("click", () => {
    dlg.close();
    let preset;
    if (isToday) {
      const next = new Date(Date.now() + 3600000);
      preset = new Date(next.getFullYear(), next.getMonth(), next.getDate(), next.getHours());
      if (!sameDay(preset, day)) preset = timeAtMinutes(startOfDay(day), 23 * 60);
    } else {
      preset = timeAtMinutes(startOfDay(day), 9 * 60);
    }
    openStartSheet(preset);
  });
  dlg.showModal();
}

function openRuleEditor(existing) {
  const dlg = $("#dlg-rule");
  let saving = false;
  const days = new Set(existing ? existing.weekdays : [2, 3, 4, 5, 6]);
  const selected = new Set(existing ? existing.blocklistIDs : blocklists.map((b) => b.id));
  const toTime = (minutes) => `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`;
  dlg.innerHTML = `
    <div class="dialog-bar"><button id="re-cancel">Cancel</button>
      <span class="title">${existing ? "Edit Schedule" : "New Schedule"}</span>
      <button id="re-save"><b>Save</b></button></div>
    <div class="dialog-body">
      <h2 class="section">Name</h2>
      <input type="text" id="re-name" placeholder="e.g. Morning Focus" value="${esc(existing ? existing.name : "")}">
      <h2 class="section">Days</h2>
      <div class="day-chips">${["S", "M", "T", "W", "T", "F", "S"].map((s, i) =>
        `<button class="day-chip ${days.has(i + 1) ? "on" : ""}" data-day="${i + 1}">${s}</button>`).join("")}</div>
      <h2 class="section">Time</h2>
      <div class="field-row">
        <input type="time" id="re-from" value="${toTime(existing ? existing.startMinutes : 540)}">
        <span class="caption">to</span>
        <input type="time" id="re-to" value="${toTime(existing ? existing.endMinutes : 660)}">
      </div>
      <p class="caption" id="re-overnight" style="margin-top:6px"></p>
      <h2 class="section">Block</h2>
      ${blocklists.length ? blocklists.map((b) => `
        <button class="row re-list" data-id="${b.id}">
          <span class="icon-circle ${selected.has(b.id) ? "" : "outlined"}">✋</span>
          <span class="row-body"><span class="row-title">${esc(b.name)}</span>
          <span class="row-sub">${esc(listSummary(b))}</span></span>
          <span class="check" style="color:var(--wine)">${selected.has(b.id) ? "●" : "○"}</span>
        </button>`).join("") : '<div class="caption">No blocklists yet — create one in the Blocklists tab first. A schedule needs at least one.</div>'}
      <h2 class="section">Options</h2>
      <label class="toggle-row"><span class="mono-wine">🔒</span>
        <span class="row-body"><span class="row-title">Locked mode</span>
        <span class="row-sub">Sessions from this schedule can't be ended early.</span></span>
        <span class="switch"><input type="checkbox" id="re-locked" ${existing?.isLocked ? "checked" : ""}><span class="knob"></span></span>
      </label>
      ${existing ? '<div style="height:14px"></div><button class="btn-quiet" id="re-delete">Delete Schedule</button>' : ""}
    </div>`;
  const parseMinutes = (value) => {
    const [h, m] = value.split(":").map(Number);
    return (h || 0) * 60 + (m || 0);
  };
  const refresh = () => {
    const from = parseMinutes($("#re-from").value), to = parseMinutes($("#re-to").value);
    $("#re-overnight").textContent = to <= from && from !== to ? "Ends the next day." : "";
  };
  dlg.querySelectorAll("[data-day]").forEach((chip) => chip.addEventListener("click", () => {
    const d = Number(chip.dataset.day);
    days.has(d) ? days.delete(d) : days.add(d);
    chip.classList.toggle("on", days.has(d));
  }));
  dlg.querySelectorAll(".re-list").forEach((row) => row.addEventListener("click", () => {
    const id = row.dataset.id;
    selected.has(id) ? selected.delete(id) : selected.add(id);
    row.querySelector(".check").textContent = selected.has(id) ? "●" : "○";
    row.querySelector(".icon-circle").classList.toggle("outlined", !selected.has(id));
  }));
  $("#re-from").addEventListener("change", refresh);
  $("#re-to").addEventListener("change", refresh);
  $("#re-cancel").addEventListener("click", () => dlg.close());
  $("#re-delete")?.addEventListener("click", () => {
    if (confirm("Delete this schedule?")) {
      mutateState(() => {
        S.rules = S.rules.filter((r) => r.id !== existing.id);
      }).then((saved) => { if (saved) { dlg.close(); render(); } });
    }
  });
  $("#re-save").addEventListener("click", async () => {
    if (saving) return;
    const from = parseMinutes($("#re-from").value), to = parseMinutes($("#re-to").value);
    if (!days.size || !selected.size || from === to) {
      alert("Pick at least one day and one blocklist, and make the start and end times different.");
      return;
    }
    const rule = {
      id: existing ? existing.id : uid(),
      name: $("#re-name").value.trim() || "Focus schedule",
      weekdays: [1, 2, 3, 4, 5, 6, 7].filter((d) => days.has(d)),
      startMinutes: from,
      endMinutes: to,
      blocklistIDs: blocklists.map((b) => b.id).filter((id) => selected.has(id)),
      isLocked: $("#re-locked").checked,
      isEnabled: existing ? existing.isEnabled : true,
    };
    const button = $("#re-save");
    saving = true;
    button.disabled = true;
    try {
      const saved = await mutateState(() => {
        rule.blocklistIDs = listsByIDs(rule.blocklistIDs).map((b) => b.id);
        if (!rule.blocklistIDs.length) {
          alert("The selected blocklists were deleted in another window.");
          return false;
        }
        if (existing) {
          const current = S.rules.find((r) => r.id === rule.id);
          if (!current) { alert("This schedule was deleted in another window."); return false; }
          rule.isEnabled = current.isEnabled;
          Object.assign(current, rule);
        } else S.rules.push(rule);
      });
      if (!saved) return;
      if ($("#re-save") === button) dlg.close();
      tick(); // a rule whose window contains "now" starts immediately
      render();
    } finally {
      saving = false;
      button.disabled = false;
    }
  });
  refresh();
  dlg.showModal();
}

// --- History tab ------------------------------------------------------------

function renderHistory() {
  const minutes = dayMinutes();
  const early = S.history.filter((r) => r.endedEarly).length;
  let html = `<h1 class="page-title">History</h1>
    <div class="stat-grid">
      <div class="stat-tile"><div class="value">${currentStreak(minutes)} <small>days</small></div><div class="label">Current streak</div></div>
      <div class="stat-tile"><div class="value">${bestStreak(minutes)} <small>days</small></div><div class="label">Best streak</div></div>
      <div class="stat-tile"><div class="value">${S.history.length - early}</div><div class="label">Sessions completed</div></div>
      <div class="stat-tile"><div class="value">${fmtDuration(totalFocusSeconds())}</div><div class="label">Total focus time</div></div>
    </div>`;

  // 26-week heatmap, current week rightmost.
  const today = startOfDay(new Date());
  const weekStart = addDays(today, -today.getDay());
  const heat = (l) => ["var(--empty)", "rgba(114,47,55,0.25)", "rgba(114,47,55,0.5)", "rgba(114,47,55,0.75)", "var(--wine)"][l];
  let cols = "";
  for (let w = 25; w >= 0; w--) {
    const colStart = addDays(weekStart, -7 * w);
    let cells = "";
    for (let d = 0; d < 7; d++) {
      const day = addDays(colStart, d);
      cells += day > today
        ? '<span class="heat-cell" style="background:transparent"></span>'
        : `<span class="heat-cell" style="background:${heat(heatLevel(minutes[dayKey(day)] || 0))}"></span>`;
    }
    cols += `<span class="heat-col">${cells}</span>`;
  }
  html += `<div class="heatmap-card"><div class="heatmap">${cols}</div>
    <div class="heat-legend">Less ${[0, 1, 2, 3, 4].map((l) => `<span class="heat-cell" style="background:${heat(l)}"></span>`).join("")} More</div></div>`;

  html += '<h2 class="section">Recent Sessions</h2>';
  const recent = [...S.history].sort((a, b) => D(b.startedAt) - D(a.startedAt)).slice(0, 15);
  html += recent.length ? recent.map((r) => `
    <div class="row"><span class="icon-circle ${r.endedEarly ? "outlined" : ""}">${r.endedEarly ? "⃠" : "✓"}</span>
      <span class="row-body"><span class="row-title">${esc(sessionTitle(r))}</span>
      <span class="row-sub">${D(r.startedAt).toLocaleDateString([], { month: "short", day: "numeric" })} at ${fmtClock(D(r.startedAt))}</span></span>
      <span class="row-trail">${fmtDuration((D(r.endedAt) - D(r.startedAt)) / 1000)}
        ${r.endedEarly ? '<span class="caption">ended early</span>' : ""}</span></div>`).join("")
    : '<div class="empty-note">No sessions yet — start your first focus session from the Focus tab.</div>';
  return html;
}

// --- Coach tab --------------------------------------------------------------

function renderCoachShell() {
  return `<div class="page-header"><h1 class="page-title">Coach</h1>
    <div class="toolbar"><button class="icon-btn" id="coach-settings">⚙︎</button></div></div>
    <div id="coach-scroll" style="padding-bottom:70px"></div>
    <div class="coach-input">
      <input type="text" id="coach-draft" placeholder="Ask your coach…" autocomplete="off">
      <button class="send-btn" id="coach-send">➤</button>
    </div>`;
}

const COACH_SUGGESTIONS = ["How am I doing this week?", "Help me plan tomorrow", "Why do I quit sessions early?"];

function renderCoach() {
  const clear = $("#st-clear");
  if (clear) clear.disabled = coachLoading;
  const scroll = $("#coach-scroll");
  if (!scroll) return;
  let html = "";
  if (!coachMessages.length) {
    html += `<div class="coach-empty"><div class="spark" style="color:var(--wine)">✦</div>
      <h3>Your focus coach</h3>
      <p class="caption">Ask anything about your focus habits — the coach sees your streaks, schedules, and session history.</p>`;
    html += coachKey()
      ? `<div class="suggestions">${COACH_SUGGESTIONS.map((s) => `<button class="btn-quiet coach-suggest" style="color:var(--wine-deep);font-size:15px">${s}</button>`).join("")}</div>`
      : `<div class="suggestions"><button class="btn-primary" id="coach-open-settings">Add an API key in Settings</button>
         <p class="caption">The coach is optional. Add your own Gemini or Claude API key in Settings; provider quotas and billing apply.</p></div>`;
    html += "</div>";
  }
  html += coachMessages.map((m) => `<div class="bubble ${m.role}">${esc(m.text)}</div>`).join("");
  if (coachLoading) html += '<div class="typing"></div>';
  if (coachError) html += `<div class="error-card">${esc(coachError)}</div>`;
  scroll.innerHTML = html;
  scroll.querySelectorAll(".coach-suggest").forEach((btn) =>
    btn.addEventListener("click", () => submitCoach(btn.textContent)));
  $("#coach-open-settings")?.addEventListener("click", openSettings);
  $("#main").scrollTop = $("#main").scrollHeight;
  const send = $("#coach-send");
  if (send) send.disabled = coachLoading;
}

function submitCoach(text) {
  if (coachLoading || !text.trim()) return Promise.resolve();
  coachDraft = "";
  const input = $("#coach-draft");
  if (input) input.value = coachDraft;
  return coachSend(text).then((restore) => {
    // Resolve the current input after awaiting; the old node may be detached.
    if (restore) {
      coachDraft = coachDraft ? restore + " " + coachDraft : restore;
      const currentInput = $("#coach-draft");
      if (currentInput) currentInput.value = coachDraft;
    }
  });
}

function wireCoach() {
  $("#coach-settings").addEventListener("click", openSettings);
  $("#coach-send").addEventListener("click", () => submitCoach(coachDraft));
  $("#coach-draft").addEventListener("input", (event) => { coachDraft = event.target.value; });
  $("#coach-draft").addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); submitCoach(coachDraft); }
  });
}

// --- Settings ---------------------------------------------------------------

function openSettings() {
  const dlg = $("#dlg-settings");
  const paint = () => {
    dlg.innerHTML = `
      <div class="dialog-bar"><span style="width:52px"></span><span class="title">Settings</span>
        <button id="st-done"><b>Done</b></button></div>
      <div class="dialog-body">
        <h2 class="section">App Blocking</h2>
        <p class="caption">The web version tracks your sessions everywhere — Android, Windows, Mac, Linux — but browsers can't close other apps. For OS-level blocking with Screen Time, use the iPhone app. Install this app from your browser menu ("Install app" / "Add to Home Screen") for a full-screen experience.</p>
        <h2 class="section">AI Coach</h2>
        <div class="segmented">
          <button id="st-gemini" class="${coachCfg.provider === "gemini" ? "on" : ""}">Gemini</button>
          <button id="st-claude" class="${coachCfg.provider === "claude" ? "on" : ""}">Claude</button>
        </div>
        <input type="password" id="st-key" placeholder="API key" value="${esc(coachCfg.keys[coachCfg.provider] || "")}" autocomplete="off">
        <p class="caption" style="margin-top:8px">${coachCfg.provider === "gemini"
          ? "Create a key at aistudio.google.com. Uses gemini-3.6-flash; availability and pricing depend on your account."
          : "Create a key at console.anthropic.com. Uses claude-haiku-4-5; availability and pricing depend on your account."}</p>
        <p class="caption" style="margin-top:6px">The key is stored in this browser only and sent to the provider you picked, along with your focus stats when you message the coach.</p>
        ${coachMessages.length ? `<div style="height:14px"></div><button class="btn-quiet" id="st-clear" ${coachLoading ? "disabled" : ""}>Clear Conversation</button>` : ""}
      </div>`;
    const displayedProvider = coachCfg.provider;
    const setProvider = async (p) => {
      const key = $("#st-key").value;
      const saved = await mutateState(() => {
        coachCfg.keys[displayedProvider] = key;
        coachCfg.provider = p;
      });
      if (saved) paint();
    };
    $("#st-gemini").addEventListener("click", () => setProvider("gemini"));
    $("#st-claude").addEventListener("click", () => setProvider("claude"));
    $("#st-key").addEventListener("input", () => {
      const key = $("#st-key").value;
      mutateState(() => { coachCfg.keys[displayedProvider] = key; });
    });
    $("#st-clear")?.addEventListener("click", () => {
      if (coachLoading) return;
      coachMessages = []; coachError = null;
      paint();
      if (currentTab === "coach") renderCoach();
    });
    $("#st-done").addEventListener("click", () => {
      dlg.close();
      if (currentTab === "coach") renderCoach();
    });
  };
  paint();
  dlg.showModal();
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

document.querySelectorAll("#tabbar button").forEach((btn) =>
  btn.addEventListener("click", () => switchTab(btn.dataset.tab)));

if ("serviceWorker" in navigator && location.protocol !== "file:") {
  navigator.serviceWorker.register("sw.js").catch(() => {});
}

// Storage events repaint only; correctness comes from reloading inside every
// transaction even when another tab's storage event has not arrived yet.
window.addEventListener("storage", (event) => {
  if (event.key === STATE_KEY || event.key === null) {
    reloadState();
    if (!S.active) Soundscape.stop();
    render();
  }
});

function seedDemoData() {
  // Demo seeding for screenshots/tests: open with #demo once. Mirrors the Swift
  // guard — never overwrite rules or queued sessions the user already has.
  if (location.hash === "#demo" && !S.history.length && !S.rules.length &&
      !S.scheduled.length && blocklists.length) {
    const now = startOfDay(new Date());
    for (let offset = 1; offset <= 120; offset++) {
      if ((offset * 7919) % 10 < 7) {
        const count = 1 + ((offset * 31) % 3);
        for (let slot = 0; slot < count; slot++) {
          const start = new Date(addDays(now, -offset).getTime() + [9, 13, 16, 20][slot % 4] * 3600000);
          const planned = 25 + ((offset * 13 + slot * 41) % 18) * 5;
          const endedEarly = (offset + slot) % 8 === 0;
          const actual = endedEarly ? Math.max(5, Math.round(planned * 0.5)) : planned;
          S.history.push({
            id: uid(), startedAt: start.toISOString(),
            endedAt: new Date(start.getTime() + actual * 60000).toISOString(),
            plannedMinutes: planned,
            blocklistNames: blocklists.map((b) => b.name),
            scheduleName: null, endedEarly,
          });
        }
      }
    }
    S.rules = [
      { id: uid(), name: "Morning Focus", weekdays: [2, 3, 4, 5, 6], startMinutes: 540, endMinutes: 660,
        blocklistIDs: blocklists.map((b) => b.id), isLocked: false, isEnabled: true },
      { id: uid(), name: "Wind Down", weekdays: [1, 2, 3, 4, 5, 6, 7], startMinutes: 1290, endMinutes: 1380,
        blocklistIDs: blocklists.length ? [blocklists[0].id] : [], isLocked: true, isEnabled: true },
    ];
    S.scheduled = [{ id: uid(), startAt: timeAtMinutes(addDays(now, 1), 9 * 60).toISOString(),
                     minutes: 45, blocklistIDs: blocklists.map((b) => b.id), isLocked: false }];
    // Pre-mark nearby occurrences so seeding never starts a session mid-demo.
    for (const rule of S.rules) {
      for (const offset of [-1, 0, 1]) {
        const occ = occurrenceStartingOn(rule, addDays(now, offset));
        if (occ) S.triggered[occurrenceKey(rule, occ.start)] = occ.end.toISOString();
      }
    }
  }
}

const ready = mutateState(seedDemoData).then(() => {
  switchTab("focus");
  tick();
  setInterval(tick, 1000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) tick(); });
});
