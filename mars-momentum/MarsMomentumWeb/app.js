import { newId, createSyncController, mergeDocs } from "./sync-core.mjs";
import { createStorageLock } from "./storage-lock.mjs";
import { createDocumentStore } from "./document-store.mjs";

"use strict";

/* Mars Momentum web — mirrors the SwiftUI app: four categories logged as
   durations or counts (weight is a plain number), a calendar with per-category
   dots, and a 26-week LeetCode-style heatmap. Data lives in localStorage. */

/* ---------- small utils ---------- */

const $ = (sel, root = document) => root.querySelector(sel);
const esc = value => String(value).replace(/[&<>"']/g, character =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[character]));
const pad2 = (n) => String(n).padStart(2, "0");

const dayKeyOf = (d) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
const keyToDate = (k) => { const [y, m, d] = k.split("-").map(Number); return new Date(y, m - 1, d); };
const addDays = (k, n) => { const d = keyToDate(k); d.setDate(d.getDate() + n); return dayKeyOf(d); };
const todayKey = () => dayKeyOf(new Date());

function weightUnit() {
  try {
    const region = new Intl.Locale(navigator.language).maximize().region;
    return ["US", "LR", "MM"].includes(region) ? "lb" : "kg";
  } catch { return "kg"; }
}
const WEIGHT_UNIT = weightUnit();

const CATEGORIES = {
  study:  { title: "Study",  icon: "📖", supportsDuration: true,  outlined: false },
  gym:    { title: "Gym",    icon: "🏋️", supportsDuration: true,  outlined: false },
  cardio: { title: "Cardio", icon: "🏃", supportsDuration: true,  outlined: false },
  weight: { title: "Weight", icon: "⚖️", supportsDuration: false, outlined: true },
};
const CATEGORY_KEYS = Object.keys(CATEGORIES);

function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "—";
  const totalMinutes = Math.round(seconds / 60);
  const h = Math.floor(totalMinutes / 60);
  const m = totalMinutes % 60;
  if (h > 0 && m > 0) return `${h}h ${m}m`;
  if (h > 0) return `${h}h`;
  return `${m}m`;
}

function formatNumber(value, unit) {
  const text = Number(value).toLocaleString(undefined, { maximumFractionDigits: 1 });
  return unit ? `${text} ${unit}` : text;
}

/* Compact duration for calendar cells: "45m", "1.5h", "2h". */
function shortDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "—";
  const totalMinutes = Math.round(seconds / 60);
  if (totalMinutes < 60) return `${totalMinutes}m`;
  // Round to tenths first so 61 minutes prints "1h", not "1.0h".
  const tenths = Math.round((totalMinutes / 60) * 10);
  return `${tenths % 10 === 0 ? tenths / 10 : (tenths / 10).toFixed(1)}h`;
}

function formatAmount(entry) {
  if (entry.kind === "duration") return formatDuration(entry.amount);
  return formatNumber(entry.amount, entry.category === "weight" ? WEIGHT_UNIT : "");
}

const timeFmt = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });
const dayTitleFmt = new Intl.DateTimeFormat(undefined, { weekday: "long", month: "short", day: "numeric" });
const monthTitleFmt = new Intl.DateTimeFormat(undefined, { month: "long", year: "numeric" });
const monthShortFmt = new Intl.DateTimeFormat(undefined, { month: "short" });

/* ---------- storage ---------- */

const STORAGE_KEY = "mars-entries";

const validEntry = (e) =>
  e && typeof e === "object" && CATEGORIES[e.category] &&
  (e.kind === "number" || e.kind === "duration") &&
  typeof e.id === "string" && e.id.length > 0 && e.id.length <= 64 &&
  typeof e.amount === "number" && isFinite(e.amount) && e.amount >= 0 &&
  typeof e.date === "string" && !isNaN(new Date(e.date));

function loadEntries() {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (raw == null) return [];
  try {
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) return parsed.filter(validEntry);
  } catch {}
  // Unreadable: keep a copy aside instead of letting the next save clobber it.
  try { localStorage.setItem(STORAGE_KEY + "-corrupt", raw); } catch {}
  return [];
}

let entries = loadEntries();

/* Per-category goals: daily duration/count for activities, target for weight. */
const GOALS_KEY = "mars-goals";

// The valid goals in category order. Documents written by earlier builds keep
// goals in the order they were saved, so anything that compares goals as JSON
// goes through this first.
function canonicalGoals(source) {
  const out = {};
  for (const c of CATEGORY_KEYS) {
    const g = source?.[c];
    if (g && (g.kind === "number" || g.kind === "duration") &&
        typeof g.amount === "number" && isFinite(g.amount) && g.amount > 0) {
      out[c] = { kind: g.kind, amount: g.amount };
    }
  }
  return out;
}

function loadGoals() {
  try {
    const raw = localStorage.getItem(GOALS_KEY);
    return raw ? canonicalGoals(JSON.parse(raw)) : {};
  } catch { return {}; }
}

let goals = loadGoals();
let goalsUpdatedAt = localStorage.getItem(GOALS_KEY + "-updated") || null;


/* Tombstones for synced deletions. */
const TOMBSTONES_KEY = "mars-tombstones";

function loadTombstones() {
  try {
    const parsed = JSON.parse(localStorage.getItem(TOMBSTONES_KEY) || "[]");
    return Array.isArray(parsed) ? parsed.filter((t) => t && typeof t.id === "string") : [];
  } catch { return []; }
}

let tombstones = loadTombstones();
const DOCUMENT_KEY = "mars-document-v1";
const withStorageLock = createStorageLock("mars-tracking-storage-lock");
const documentStore = createDocumentStore({
  storage: localStorage,
  key: DOCUMENT_KEY,
  withLock: withStorageLock,
  loadLegacy: () => ({ entries: loadEntries(), tombstones: loadTombstones(), goals: loadGoals(),
    goalsUpdatedAt: localStorage.getItem(GOALS_KEY + "-updated") || null }),
});

function storageFailure(error) {
  window.alert(`Your change could not be saved. ${error.message || error}`);
}

async function mutateDoc(change) {
  const saved = await documentStore.update(latest => {
    refreshPersistedAccount();
    return change(latest);
  });
  adoptDoc(saved);
  scheduleSync();
  render();
}

function formatGoalValue(goal) {
  return goal.kind === "duration" ? formatDuration(goal.amount) : formatNumber(goal.amount);
}

/* ---------- account & sync ---------- */

const ACCOUNT_KEY = "mars-account";
const LAST_SYNC_KEY = "mars-last-sync";

function loadAccount() {
  try {
    const parsed = JSON.parse(localStorage.getItem(ACCOUNT_KEY) || "null");
    if (parsed && typeof parsed.server === "string" &&
        typeof parsed.username === "string" && typeof parsed.token === "string") {
      return parsed;
    }
  } catch {}
  return null;
}

let account = loadAccount();
let syncState = "idle"; // "idle" | "syncing" | error message string
let syncTimer = null;
let accountGeneration = 0;
const syncController = createSyncController({
  readDoc: currentDoc,
  applyDoc,
  request: (doc, auth) => api("/api/sync", { body: doc, auth }),
  onState: state => { syncState = state; refreshAccountDialog(); },
  onSynced: () => localStorage.setItem(LAST_SYNC_KEY, new Date().toISOString()),
});
syncController.setAccount(account);

function refreshPersistedAccount() {
  const next = loadAccount();
  if (JSON.stringify(next) !== JSON.stringify(account)) {
    accountGeneration += 1;
    clearTimeout(syncTimer);
    account = next;
    syncController.setAccount(account);
  }
  return next;
}

async function api(path, { body, auth } = {}) {
  const credentials = auth === undefined ? account : auth;
  const base = (credentials?.server ?? "").replace(/\/+$/, "");
  const headers = { "Content-Type": "application/json" };
  const user = credentials?.username;
  const token = credentials?.token;
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
    headers["X-Mars-User"] = user;
  }
  let response;
  try {
    response = await fetch(`${base}${path}`, {
      method: "POST",
      headers,
      body: JSON.stringify(body ?? {}),
    });
  } catch {
    throw new Error(`Can't reach ${base || "server"}`);
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `Server error (${response.status})`);
  return data;
}

function currentDoc() {
  return { entries, tombstones, goals, goalsUpdatedAt };
}

function adoptDoc(doc) {
  entries = Array.isArray(doc.entries) ? doc.entries.filter(validEntry) : [];
  tombstones = Array.isArray(doc.tombstones) ? doc.tombstones.filter((t) => t && typeof t.id === "string") : [];
  goals = canonicalGoals(doc.goals);
  goalsUpdatedAt = doc.goalsUpdatedAt || null;
}

async function applyDoc(doc, context) {
  const saved = await documentStore.update(latest => {
    if (!context) return mergeDocs(doc, latest);
    if (!context.isCurrent()) return latest;
    const persistedAccount = refreshPersistedAccount();
    if (JSON.stringify(persistedAccount) !== JSON.stringify(context.session)) {
      return latest;
    }
    // What was sent came from memory, where goals are in category order. Read
    // the stored goals the same way, or key order alone looks like a new edit
    // and the sync loop never settles.
    const stored = { ...latest, goals: canonicalGoals(latest.goals) };
    // Another tab may have committed after the request began but before its
    // storage event reached this tab. Drain those edits to the server as well.
    if (JSON.stringify(stored) !== JSON.stringify(context.sent)) syncController.mutated();
    const goalsChanged = stored.goalsUpdatedAt !== context.sent.goalsUpdatedAt ||
      JSON.stringify(stored.goals) !== JSON.stringify(context.sent.goals);
    return mergeDocs(context.response, stored, goalsChanged);
  });
  adoptDoc(saved);
}

async function syncNow() {
  await syncController.sync();
  render();
}

function scheduleSync() {
  syncController.mutated();
  if (!account) return;
  clearTimeout(syncTimer);
  syncTimer = setTimeout(syncNow, 2000);
}

async function signIn(server, username, password, creating) {
  let parsed;
  try { parsed = new URL(server.trim()); } catch { throw new Error("Enter a valid server URL"); }
  if (!["http:", "https:"].includes(parsed.protocol) || parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error("Use an HTTP or HTTPS server URL without credentials, query or fragment");
  }
  const base = parsed.href.replace(/\/+$/, "");
  const generation = ++accountGeneration;
  const name = username.toLowerCase().trim();
  const data = await api(creating ? "/api/register" : "/api/login", {
    body: { username: name, password },
    auth: { server: base, username: name, token: null },
  });
  if (generation !== accountGeneration) return;
  if (typeof data.username !== "string" || typeof data.token !== "string") throw new Error("Invalid sign-in response");
  await withStorageLock(() => {
    if (generation !== accountGeneration) return;
    const next = { server: base, username: data.username, token: data.token };
    localStorage.setItem(ACCOUNT_KEY, JSON.stringify(next));
    account = next;
    syncController.setAccount(account);
  });
  if (generation !== accountGeneration) return;
  await syncNow();
  if (syncState !== "idle") throw new Error(syncState);
}

async function signOut() {
  const previous = account;
  accountGeneration += 1;
  clearTimeout(syncTimer);
  syncController.setAccount(null);
  const generation = accountGeneration;
  try {
    await withStorageLock(() => {
      if (generation !== accountGeneration) return;
      localStorage.removeItem(ACCOUNT_KEY);
      localStorage.removeItem(LAST_SYNC_KEY);
      account = null;
    });
  } catch (error) {
    if (generation === accountGeneration) syncController.setAccount(previous);
    throw error;
  }
  // End the local session immediately; a late logout cannot clear a new login.
  if (previous) {
    try { await api("/api/logout", { auth: previous }); } catch {}
  }
}

/* Achieved-vs-target for an activity's daily goal; only matching-kind entries count. */
function goalProgress(category, key) {
  if (category === "weight") return null;
  const goal = goals[category];
  if (!goal) return null;
  const achieved = entriesOn(key, category)
    .filter((e) => e.kind === goal.kind)
    .reduce((s, e) => s + e.amount, 0);
  return { achieved, goal };
}

function goalsMetCount(category) {
  const goal = goals[category];
  if (!goal || category === "weight") return 0;
  const byDay = new Map();
  for (const e of entries) {
    if (e.category !== category || e.kind !== goal.kind) continue;
    const k = entryDayKey(e);
    byDay.set(k, (byDay.get(k) || 0) + e.amount);
  }
  let met = 0;
  for (const total of byDay.values()) if (total >= goal.amount - 1e-9) met++;
  return met;
}

async function addEntry(category, kind, amount, key) {
  let date;
  if (key === todayKey()) {
    date = new Date();
  } else {
    date = keyToDate(key);
    date.setHours(12, 0, 0, 0);
  }
  const entry = { id: newId(), date: date.toISOString(), category, kind, amount };
  await mutateDoc(latest => ({ ...latest, entries: [...latest.entries, entry] }));
}

async function deleteEntry(id) {
  // Tombstone so the deletion survives the union-based sync merge.
  await mutateDoc(latest => ({ ...latest,
    entries: latest.entries.filter(e => e.id !== id),
    tombstones: [...latest.tombstones, { id, deletedAt: new Date().toISOString() }],
  }));
}

/* ---------- queries (mirror EntryStore) ---------- */

const entryDayKey = (e) => dayKeyOf(new Date(e.date));

function entriesOn(key, category) {
  return entries
    .filter((e) => entryDayKey(e) === key && (!category || e.category === category))
    .sort((a, b) => new Date(a.date) - new Date(b.date));
}

function categoriesLogged(key) {
  const logged = new Set(entriesOn(key).map((e) => e.category));
  return CATEGORY_KEYS.filter((c) => logged.has(c));
}

function summary(category, key) {
  const dayEntries = entriesOn(key, category);
  if (!dayEntries.length) return null;
  if (category === "weight") return formatAmount(dayEntries[dayEntries.length - 1]);
  const duration = dayEntries.filter((e) => e.kind === "duration").reduce((s, e) => s + e.amount, 0);
  const number = dayEntries.filter((e) => e.kind === "number").reduce((s, e) => s + e.amount, 0);
  const parts = [];
  if (duration > 0) parts.push(formatDuration(duration));
  if (number > 0) parts.push(`×${formatNumber(number)}`);
  return parts.length ? parts.join(" · ") : null;
}

function dayBuckets(filter) {
  const buckets = new Map();
  for (const e of entries) {
    if (filter && e.category !== filter) continue;
    const k = entryDayKey(e);
    if (!buckets.has(k)) buckets.set(k, []);
    buckets.get(k).push(e);
  }
  return buckets;
}

function levelFor(dayEntries, filter) {
  if (!dayEntries.length) return 0;
  if (!filter) return Math.min(4, new Set(dayEntries.map((e) => e.category)).size);
  if (filter === "weight") return 4;
  const goal = goals[filter];
  if (goal) {
    // Goal-aware intensity: partial shades are fractions of the daily goal,
    // full wine means the goal was met (LeetCode "solved" style).
    const achieved = dayEntries.filter((e) => e.kind === goal.kind).reduce((s, e) => s + e.amount, 0);
    const fraction = achieved / goal.amount;
    // Small tolerance so 0.1 + 0.7 counts against a 0.8 goal despite IEEE sums.
    if (fraction >= 1 - 1e-9) return 4;
    return Math.max(1, Math.min(3, Math.ceil(fraction * 3)));
  }
  const minutes = dayEntries.filter((e) => e.kind === "duration").reduce((s, e) => s + e.amount, 0) / 60;
  const countEntries = dayEntries.filter((e) => e.kind === "number").length;
  const score = Math.ceil(minutes / 30) + countEntries;
  return Math.max(1, Math.min(4, score));
}

/* Compact per-day value for the calendar's Numbers mode. */
function calendarValue(key, filter) {
  if (!filter) {
    const count = entriesOn(key).length;
    return count ? String(count) : null;
  }
  const list = entriesOn(key, filter);
  if (!list.length) return null;
  if (filter === "weight") return formatNumber(list[list.length - 1].amount);
  const duration = list.filter((e) => e.kind === "duration").reduce((s, e) => s + e.amount, 0);
  if (duration > 0) return shortDuration(duration);
  const number = list.filter((e) => e.kind === "number").reduce((s, e) => s + e.amount, 0);
  return number > 0 ? `×${formatNumber(number)}` : null;
}

function activeDaySet(filter) {
  const set = new Set();
  for (const e of entries) {
    if (filter && e.category !== filter) continue;
    set.add(entryDayKey(e));
  }
  return set;
}

function currentStreak(filter) {
  const active = activeDaySet(filter);
  let k = todayKey();
  if (!active.has(k)) k = addDays(k, -1);
  let streak = 0;
  while (active.has(k)) { streak++; k = addDays(k, -1); }
  return streak;
}

function bestStreak(filter) {
  const active = activeDaySet(filter);
  let best = 0;
  for (const k of active) {
    if (active.has(addDays(k, -1))) continue; // only count from a run's first day
    let length = 1;
    let cursor = k;
    while (active.has(addDays(cursor, 1))) { length++; cursor = addDays(cursor, 1); }
    best = Math.max(best, length);
  }
  return best;
}

function totalSummary(filter) {
  const relevant = filter ? entries.filter((e) => e.category === filter) : entries;
  if (filter === "weight") {
    if (!relevant.length) return "—";
    let latest = relevant[0];
    for (const e of relevant) if (new Date(e.date) >= new Date(latest.date)) latest = e;
    return formatAmount(latest);
  }
  if (!filter) return String(relevant.length);
  const duration = relevant.filter((e) => e.kind === "duration").reduce((s, e) => s + e.amount, 0);
  const number = relevant.filter((e) => e.kind === "number").reduce((s, e) => s + e.amount, 0);
  const parts = [];
  if (duration > 0) parts.push(formatDuration(duration));
  if (number > 0) parts.push(`×${formatNumber(number)}`);
  return parts.length ? parts.join(" · ") : "0";
}

/* ---------- rendering ---------- */

const main = $("#main");
let currentTab = "today";
let calMonth = (() => { const d = new Date(); return { year: d.getFullYear(), month: d.getMonth() }; })();
let progressFilter = null;
let openDayKey = null; // day dialog state, so it can re-render after edits

function categoryIconHTML(category, size) {
  const meta = CATEGORIES[category];
  return `<span class="cat-icon ${meta.outlined ? "outlined" : ""} cat-${category}" style="width:${size}px;height:${size}px">${meta.icon}</span>`;
}

function render() {
  document.querySelectorAll("#tabbar button").forEach((b) =>
    b.classList.toggle("active", b.dataset.tab === currentTab));
  if (currentTab === "today") renderToday();
  else if (currentTab === "calendar") renderCalendar();
  else renderProgress();
  if (openDayKey && $("#dlg-day").open) renderDayDialog(openDayKey);
}

/* ----- Today ----- */

function entryRowHTML(e) {
  return `
    <div class="entry-row">
      ${categoryIconHTML(e.category, 34)}
      <div class="entry-main">
        <div class="entry-title">${CATEGORIES[e.category].title}</div>
        <div class="entry-time">${timeFmt.format(new Date(e.date))}</div>
      </div>
      <div class="entry-amount">${formatAmount(e)}</div>
      <button class="entry-delete" data-id="${esc(e.id)}" aria-label="Delete ${CATEGORIES[e.category].title} entry">✕</button>
    </div>`;
}

function bindEntryDeletes(root) {
  root.querySelectorAll(".entry-delete").forEach((btn) => {
    btn.addEventListener("click", () => {
      const entry = entries.find((e) => e.id === btn.dataset.id);
      if (!entry) return;
      if (confirm(`Delete this ${CATEGORIES[entry.category].title.toLowerCase()} entry?`)) {
        deleteEntry(btn.dataset.id).catch(storageFailure);
      }
    });
  });
}

function renderToday() {
  const key = todayKey();
  const cards = CATEGORY_KEYS.map((c) => {
    const meta = CATEGORIES[c];
    const progress = goalProgress(c, key);
    const met = progress && progress.achieved >= progress.goal.amount - 1e-9;
    let subtitle;
    if (progress) {
      const achieved = progress.goal.kind === "duration"
        ? formatDuration(progress.achieved)
        : formatNumber(progress.achieved);
      subtitle = `${achieved} / ${formatGoalValue(progress.goal)}`;
    } else if (c === "weight" && goals.weight) {
      subtitle = `${summary(c, key) ?? "—"} → ${formatNumber(goals.weight.amount)} ${WEIGHT_UNIT}`;
    } else {
      subtitle = summary(c, key) ?? "—";
    }
    const bar = progress
      ? `<div class="goal-bar"><span style="width:${Math.min(100, Math.max(3, (progress.achieved / progress.goal.amount) * 100))}%"></span></div>`
      : "";
    return `
      <button class="cat-card cat-${c} ${meta.outlined ? "outlined" : ""}" data-cat="${c}">
        <div class="cat-card-top"><span class="cat-glyph">${meta.icon}</span><span class="cat-plus">${met ? "✓" : "+"}</span></div>
        <div class="cat-name">${meta.title}</div>
        <div class="cat-summary">${subtitle}</div>
        ${bar}
      </button>`;
  }).join("");

  const dayEntries = entriesOn(key);
  main.innerHTML = `
    <div class="title-row">
      <h1 class="page-title">Mars Momentum</h1>
      <span class="title-actions">
        <button id="account-btn" class="icon-btn ${account ? "active" : ""}" aria-label="Account & sync">👤</button>
        <button id="goals-btn" class="icon-btn" aria-label="Edit goals">🎯</button>
      </span>
    </div>
    <div class="card-grid">${cards}</div>
    <h2 class="section-title">Today's Log</h2>
    ${dayEntries.length
      ? dayEntries.map(entryRowHTML).join("")
      : `<p class="empty-note">Nothing logged yet — tap a card to add your first entry.</p>`}
  `;
  $("#goals-btn").addEventListener("click", openGoalsDialog);
  $("#account-btn").addEventListener("click", openAccountDialog);
  main.querySelectorAll(".cat-card").forEach((card) =>
    card.addEventListener("click", () => openAddDialog(card.dataset.cat, key)));
  bindEntryDeletes(main);
}

/* ----- goals dialog ----- */

function openGoalsDialog() {
  const dlg = $("#dlg-goals");
  const activityRow = (c) => {
    const g = goals[c];
    const kind = g?.kind ?? "duration";
    const hours = g && g.kind === "duration" ? Math.floor(g.amount / 3600) : 1;
    const minutes = g && g.kind === "duration" ? (g.amount % 3600) / 60 : 0;
    const hourOptions = [...new Set([...Array.from({ length: 13 }, (_, i) => i), hours])].sort((a, b) => a - b);
    const minuteOptions = [...new Set([0, 15, 30, 45, minutes])].sort((a, b) => a - b);
    const numberValue = g && g.kind === "number" ? g.amount : "";
    return `
      <fieldset class="goal-row" data-cat="${c}">
        <label class="goal-head">
          <input type="checkbox" class="goal-on" ${g ? "checked" : ""}>
          <span>${CATEGORIES[c].icon} ${CATEGORIES[c].title} — daily goal</span>
        </label>
        <div class="goal-fields" ${g ? "" : "hidden"}>
          <select class="goal-kind">
            <option value="duration" ${kind === "duration" ? "selected" : ""}>Duration</option>
            <option value="number" ${kind === "number" ? "selected" : ""}>Count</option>
          </select>
          <span class="goal-duration" ${kind === "duration" ? "" : "hidden"}>
            <select class="goal-h">${hourOptions.map((i) =>
              `<option value="${i}" ${i === hours ? "selected" : ""}>${i} h</option>`).join("")}</select>
            <select class="goal-m">${minuteOptions.map((v) =>
              `<option value="${v}" ${v === minutes ? "selected" : ""}>${v} m</option>`).join("")}</select>
          </span>
          <input class="goal-n" type="number" inputmode="decimal" step="any" min="0"
                 placeholder="e.g. 2" value="${numberValue}" ${kind === "number" ? "" : "hidden"}>
        </div>
      </fieldset>`;
  };
  dlg.innerHTML = `
    <form method="dialog" class="goals-form">
      <div class="add-header">
        <div class="add-title">Goals</div>
        <button type="button" class="dlg-close" aria-label="Cancel">✕</button>
      </div>
      ${CATEGORY_KEYS.filter((c) => c !== "weight").map(activityRow).join("")}
      <fieldset class="goal-row" data-cat="weight">
        <label class="goal-head">
          <input type="checkbox" class="goal-on" ${goals.weight ? "checked" : ""}>
          <span>${CATEGORIES.weight.icon} Target weight</span>
        </label>
        <div class="goal-fields" ${goals.weight ? "" : "hidden"}>
          <input class="goal-n" type="number" inputmode="decimal" step="any" min="0"
                 placeholder="e.g. 70" value="${goals.weight ? goals.weight.amount : ""}">
          <span class="number-unit">${WEIGHT_UNIT}</span>
        </div>
      </fieldset>
      <button type="submit" class="save-btn">Save</button>
    </form>`;

  const rowDraft = row => JSON.stringify([...row.querySelectorAll("input, select")]
    .map(input => input.type === "checkbox" ? input.checked : input.value));
  const originalDrafts = new Map([...dlg.querySelectorAll(".goal-row")].map(row => [row, rowDraft(row)]));
  dlg.querySelectorAll(".goal-row").forEach((row) => {
    const toggle = row.querySelector(".goal-on");
    toggle.addEventListener("change", () => {
      row.querySelector(".goal-fields").hidden = !toggle.checked;
    });
    const kindSelect = row.querySelector(".goal-kind");
    if (kindSelect) {
      kindSelect.addEventListener("change", () => {
        const isDuration = kindSelect.value === "duration";
        row.querySelector(".goal-duration").hidden = !isDuration;
        row.querySelector(".goal-n").hidden = isDuration;
      });
    }
  });
  $(".dlg-close", dlg).addEventListener("click", () => dlg.close());
  $(".goals-form", dlg).addEventListener("submit", async event => {
    event.preventDefault();
    const saveButton = dlg.querySelector('[type="submit"]');
    if (saveButton.disabled) return;
    saveButton.disabled = true;
    try {
      await mutateDoc(latest => {
        const next = { ...latest.goals };
        dlg.querySelectorAll(".goal-row").forEach((row) => {
          const cat = row.dataset.cat;
          // Preserve exact values outside the pickers' range, and goals updated by
          // another tab while this dialog was open, when this row was untouched.
          if (rowDraft(row) === originalDrafts.get(row)) return;
          if (!row.querySelector(".goal-on").checked) { delete next[cat]; return; }
          const kindSelect = row.querySelector(".goal-kind");
          if (kindSelect && kindSelect.value === "duration") {
            const seconds = Number(row.querySelector(".goal-h").value) * 3600 +
                            Number(row.querySelector(".goal-m").value) * 60;
            if (Number.isFinite(seconds) && seconds > 0) next[cat] = { kind: "duration", amount: seconds };
            // Enabled but zero: keep the old goal rather than silently deleting it.
          } else {
            const value = Number(String(row.querySelector(".goal-n").value).replace(",", "."));
            if (isFinite(value) && value > 0 && value <= 999999) next[cat] = { kind: "number", amount: value };
          }
        });
        const saved = canonicalGoals(next);
        const unchanged = JSON.stringify(saved) === JSON.stringify(canonicalGoals(latest.goals));
        return { ...latest, goals: saved,
          goalsUpdatedAt: unchanged ? latest.goalsUpdatedAt : new Date().toISOString() };
      });
      dlg.close();
    } catch (error) { storageFailure(error); }
    finally { saveButton.disabled = false; }
  });
  dlg.showModal();
}

/* ----- account dialog ----- */

function refreshAccountDialog() {
  const dlg = $("#dlg-account");
  if (dlg.open) renderAccountDialog();
}

function openAccountDialog() {
  renderAccountDialog();
  $("#dlg-account").showModal();
}

function renderAccountDialog() {
  const dlg = $("#dlg-account");
  if (account) {
    const last = localStorage.getItem(LAST_SYNC_KEY);
    const status = syncState === "syncing" ? "Syncing…"
      : syncState !== "idle" ? syncState
      : last ? `Last synced ${new Date(last).toLocaleString()}` : "Not synced yet";
    dlg.innerHTML = `
      <div class="add-header">
        <div class="add-title">Account</div>
        <button type="button" class="dlg-close" aria-label="Close">✕</button>
      </div>
      <div class="account-info">
        <div><span class="account-label">Signed in as</span> <strong>${esc(account.username)}</strong></div>
        <div><span class="account-label">Server</span> ${esc(account.server)}</div>
        <div class="account-status ${syncState !== "idle" && syncState !== "syncing" ? "error" : ""}">${esc(status)}</div>
      </div>
      <button type="button" class="save-btn" id="sync-now-btn" ${syncState === "syncing" ? "disabled" : ""}>Sync Now</button>
      <button type="button" class="ghost-btn" id="sign-out-btn">Sign Out</button>
      <p class="account-note">Signing out keeps this device's data; it just stops syncing.</p>`;
    $("#sync-now-btn", dlg).addEventListener("click", syncNow);
    $("#sign-out-btn", dlg).addEventListener("click", async () => {
      try {
        await signOut();
        renderAccountDialog();
        render();
      } catch (error) { storageFailure(error); }
    });
  } else {
    const defaultServer = /^https?:/.test(location.origin) ? location.origin : "http://localhost:8473";
    dlg.innerHTML = `
      <form class="account-form" method="dialog">
        <div class="add-header">
          <div class="add-title">Account</div>
          <button type="button" class="dlg-close" aria-label="Cancel">✕</button>
        </div>
        <label class="account-field">Server
          <input id="acct-server" type="url" value="${defaultServer}" autocapitalize="none" autocomplete="url">
        </label>
        <label class="account-field">Username
          <input id="acct-user" autocapitalize="none" autocomplete="username" minlength="3" maxlength="32">
        </label>
        <label class="account-field">Password
          <input id="acct-pass" type="password" autocomplete="current-password" minlength="8">
        </label>
        <div class="account-error" id="acct-error"></div>
        <button type="button" class="save-btn" id="acct-signin">Sign In</button>
        <button type="button" class="ghost-btn" id="acct-register">Create Account</button>
        <p class="account-note">One account, every device — your data syncs to your own server and back.</p>
      </form>`;
    const attempt = async (creating) => {
      const error = $("#acct-error", dlg);
      error.textContent = "";
      try {
        await signIn($("#acct-server", dlg).value, $("#acct-user", dlg).value, $("#acct-pass", dlg).value, creating);
        renderAccountDialog();
        render();
      } catch (e) {
        error.textContent = String(e.message || e);
      }
    };
    $("#acct-signin", dlg).addEventListener("click", () => attempt(false));
    $("#acct-register", dlg).addEventListener("click", () => attempt(true));
  }
  $(".dlg-close", dlg).addEventListener("click", () => dlg.close());
}

/* ----- add dialog ----- */

function openAddDialog(category, key) {
  const meta = CATEGORIES[category];
  const dlg = $("#dlg-add");
  const kind = meta.supportsDuration ? "duration" : "number";
  const isToday = key === todayKey();
  dlg.innerHTML = `
    <form method="dialog" class="add-form" data-cat="${category}" data-key="${key}">
      <div class="add-header">
        ${categoryIconHTML(category, 40)}
        <div>
          <div class="add-title">Log ${meta.title}</div>
          <div class="add-date">${isToday ? "Today" : dayTitleFmt.format(keyToDate(key))}</div>
        </div>
        <button type="button" class="dlg-close" aria-label="Cancel">✕</button>
      </div>
      ${meta.supportsDuration ? `
        <div class="segmented" role="tablist">
          <button type="button" data-kind="duration" class="active">Duration</button>
          <button type="button" data-kind="number">Count</button>
        </div>` : ""}
      <div class="kind-pane" data-pane="duration" ${kind === "duration" ? "" : "hidden"}>
        <div class="duration-row">
          <label>Hours
            <select id="add-hours">${Array.from({ length: 13 }, (_, i) =>
              `<option value="${i}" ${i === 0 ? "selected" : ""}>${i} h</option>`).join("")}</select>
          </label>
          <label>Minutes
            <select id="add-minutes">${Array.from({ length: 60 }, (_, i) =>
              `<option value="${i}" ${i === 30 ? "selected" : ""}>${i} m</option>`).join("")}</select>
          </label>
        </div>
      </div>
      <div class="kind-pane" data-pane="number" ${kind === "number" ? "" : "hidden"}>
        <div class="number-row">
          <input id="add-number" type="number" inputmode="decimal" step="any" min="0"
                 placeholder="${category === "weight" ? "72.5" : "0"}">
          ${category === "weight" ? `<span class="number-unit">${WEIGHT_UNIT}</span>` : ""}
        </div>
      </div>
      <button type="submit" class="save-btn">Save</button>
    </form>`;

  let activeKind = kind;
  dlg.querySelectorAll(".segmented button").forEach((b) =>
    b.addEventListener("click", () => {
      activeKind = b.dataset.kind;
      dlg.querySelectorAll(".segmented button").forEach((x) => x.classList.toggle("active", x === b));
      dlg.querySelectorAll(".kind-pane").forEach((p) => (p.hidden = p.dataset.pane !== activeKind));
      if (activeKind === "number") $("#add-number", dlg).focus();
    }));
  $(".dlg-close", dlg).addEventListener("click", () => dlg.close());

  let saved = false; // double-submit guard
  $(".add-form", dlg).addEventListener("submit", async (ev) => {
    ev.preventDefault();
    if (saved) return;
    let amount;
    if (activeKind === "duration") {
      amount = Number($("#add-hours", dlg).value) * 3600 + Number($("#add-minutes", dlg).value) * 60;
    } else {
      amount = Number(String($("#add-number", dlg).value).replace(",", "."));
    }
    if (!isFinite(amount) || amount <= 0 || (activeKind === "number" && amount > 999999)) {
      ev.preventDefault();
      $("#add-number", dlg)?.reportValidity?.();
      return;
    }
    saved = true;
    try {
      await addEntry(category, activeKind, amount, key);
      dlg.close();
    } catch (error) { saved = false; storageFailure(error); }
  });

  dlg.showModal();
  if (kind === "number") $("#add-number", dlg).focus();
}

/* ----- Calendar ----- */

function firstWeekday() {
  // 0 = Sunday ... 6 = Saturday, matching Date.getDay()
  try {
    const info = new Intl.Locale(navigator.language).getWeekInfo?.() ??
                 new Intl.Locale(navigator.language).weekInfo;
    if (info && info.firstDay) return info.firstDay % 7; // spec: 1 = Mon ... 7 = Sun
  } catch {}
  return 0;
}
const FIRST_WEEKDAY = firstWeekday();

function weekdayLabels() {
  const base = keyToDate("2024-01-07"); // a Sunday
  return Array.from({ length: 7 }, (_, i) => {
    const d = new Date(base);
    d.setDate(d.getDate() + ((FIRST_WEEKDAY + i) % 7));
    return new Intl.DateTimeFormat(undefined, { weekday: "narrow" }).format(d);
  });
}

let calMode = "dots"; // "dots" | "numbers" | "heat"
let calFilter = null;

function chipRowHTML(current) {
  return [["", "All"], ...CATEGORY_KEYS.map((c) => [c, CATEGORIES[c].title])]
    .map(([value, label]) =>
      `<button class="chip ${String(current ?? "") === value ? "active" : ""}" data-filter="${value}">${label}</button>`)
    .join("");
}

function renderCalendar() {
  const { year, month } = calMonth;
  const first = new Date(year, month, 1);
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const leading = (first.getDay() - FIRST_WEEKDAY + 7) % 7;
  const tKey = todayKey();
  const buckets = calMode === "heat" ? dayBuckets(calFilter) : null;

  let cells = "";
  for (let i = 0; i < leading; i++) cells += `<div class="day-cell blank"></div>`;
  for (let d = 1; d <= daysInMonth; d++) {
    const key = `${year}-${pad2(month + 1)}-${pad2(d)}`;
    const isToday = key === tKey;
    const isFuture = key > tKey;
    let content;
    if (calMode === "numbers") {
      const value = isFuture ? null : calendarValue(key, calFilter);
      content = `
        <span class="day-num-sm ${isToday ? "today" : ""} ${isFuture ? "future" : ""}">${d}</span>
        <span class="day-val">${value ?? ""}</span>`;
    } else if (calMode === "heat") {
      const level = isFuture ? 0 : levelFor(buckets.get(key) ?? [], calFilter);
      content = `
        <span class="day-heat l${level} ${isToday ? "today-ring" : ""} ${isFuture ? "future" : ""}">${d}</span>`;
    } else {
      const dots = categoriesLogged(key)
        .map((c) => `<span class="dot ${CATEGORIES[c].outlined ? "dot-outlined" : `dot-${c}`}"></span>`)
        .join("");
      content = `
        <span class="day-num ${isToday ? "today" : ""}">${d}</span>
        <span class="dots">${dots}</span>`;
    }
    cells += `<div class="day-cell ${isFuture ? "future" : ""}" data-key="${isFuture ? "" : key}">${content}</div>`;
  }

  let legend;
  if (calMode === "dots") {
    legend = CATEGORY_KEYS.map((c) =>
      `<span class="legend-item"><span class="dot ${CATEGORIES[c].outlined ? "dot-outlined" : `dot-${c}`}"></span>${CATEGORIES[c].title}</span>`).join("");
  } else if (calMode === "numbers") {
    legend = `<span class="legend-item">${
      !calFilter ? "Entries logged per day"
        : calFilter === "weight" ? "Last weigh-in of each day"
        : `Daily ${CATEGORIES[calFilter].title.toLowerCase()} total`}</span>`;
  } else if (calFilter === "weight") {
    // Weigh-ins are binary — no intensity ramp to explain.
    legend = `<span class="heat-cell l4"></span><span class="legend-item">Logged</span>`;
  } else {
    const goalNote = calFilter && goals[calFilter] ? `<span class="legend-item">· full = goal met</span>` : "";
    legend = `<span class="legend-item">Less</span>${[0, 1, 2, 3, 4].map((l) =>
      `<span class="heat-cell l${l}"></span>`).join("")}<span class="legend-item">More</span>${goalNote}`;
  }

  main.innerHTML = `
    <h1 class="page-title">Calendar</h1>
    <div class="segmented mode-seg">
      ${["dots", "numbers", "heat"].map((m) =>
        `<button data-mode="${m}" class="${calMode === m ? "active" : ""}">${m[0].toUpperCase() + m.slice(1)}</button>`).join("")}
    </div>
    ${calMode !== "dots" ? `<div class="chips">${chipRowHTML(calFilter)}</div>` : ""}
    <div class="month-header">
      <button class="month-nav" id="prev-month" aria-label="Previous month">‹</button>
      <div class="month-title">${monthTitleFmt.format(first)}</div>
      <button class="month-nav" id="next-month" aria-label="Next month">›</button>
    </div>
    <div class="weekday-row">${weekdayLabels().map((s) => `<span>${s}</span>`).join("")}</div>
    <div class="month-grid">${cells}</div>
    <div class="legend">${legend}</div>`;

  main.querySelectorAll(".mode-seg button").forEach((b) =>
    b.addEventListener("click", () => { calMode = b.dataset.mode; renderCalendar(); }));
  main.querySelectorAll(".chip").forEach((chip) =>
    chip.addEventListener("click", () => { calFilter = chip.dataset.filter || null; renderCalendar(); }));
  $("#prev-month").addEventListener("click", () => shiftMonth(-1));
  $("#next-month").addEventListener("click", () => shiftMonth(1));
  main.querySelectorAll(".day-cell[data-key]").forEach((cell) => {
    if (!cell.dataset.key) return;
    cell.addEventListener("click", () => openDayDialog(cell.dataset.key));
  });
}

function shiftMonth(delta) {
  const d = new Date(calMonth.year, calMonth.month + delta, 1);
  calMonth = { year: d.getFullYear(), month: d.getMonth() };
  renderCalendar();
}

function openDayDialog(key) {
  openDayKey = key;
  renderDayDialog(key);
  const dlg = $("#dlg-day");
  if (!dlg.open) dlg.showModal();
}

function renderDayDialog(key) {
  const dlg = $("#dlg-day");
  const dayEntries = entriesOn(key);
  dlg.innerHTML = `
    <div class="day-dialog">
      <div class="add-header">
        <div class="add-title">${dayTitleFmt.format(keyToDate(key))}</div>
        <button type="button" class="dlg-close" aria-label="Close">✕</button>
      </div>
      <div class="quick-add">
        ${CATEGORY_KEYS.map((c) => `
          <button class="quick-add-btn cat-${c} ${CATEGORIES[c].outlined ? "outlined" : ""}" data-cat="${c}">
            <span>${CATEGORIES[c].icon}</span>${CATEGORIES[c].title}
          </button>`).join("")}
      </div>
      ${dayEntries.length
        ? dayEntries.map(entryRowHTML).join("")
        : `<p class="empty-note">Nothing logged on this day.</p>`}
    </div>`;
  $(".dlg-close", dlg).addEventListener("click", () => { dlg.close(); openDayKey = null; });
  dlg.querySelectorAll(".quick-add-btn").forEach((b) =>
    b.addEventListener("click", () => openAddDialog(b.dataset.cat, key)));
  bindEntryDeletes(dlg);
}

/* ----- Progress ----- */

const WEEKS_TO_SHOW = 26;

/* Weeks: columns of 7 day-keys, ending with the current (possibly partial) week. */
function weeksFor(count) {
  const tKey = todayKey();
  const today = keyToDate(tKey);
  const daysIntoWeek = (today.getDay() - FIRST_WEEKDAY + 7) % 7;
  const currentWeekStart = addDays(tKey, -daysIntoWeek);
  const weeks = [];
  for (let w = count - 1; w >= 0; w--) {
    const start = addDays(currentWeekStart, -7 * w);
    weeks.push(Array.from({ length: 7 }, (_, i) => addDays(start, i)));
  }
  return weeks;
}

function categoryTileHTML(c) {
  const tKey = todayKey();
  const buckets = dayBuckets(c);
  const grid = weeksFor(16).map((week) => `
    <span class="tile-col">
      ${week.map((k) => {
        if (k > tKey) return `<span class="tile-cell" style="visibility:hidden"></span>`;
        return `<span class="tile-cell l${levelFor(buckets.get(k) ?? [], c)}"></span>`;
      }).join("")}
    </span>`).join("");
  const streak = currentStreak(c);
  const detail = c === "weight"
    ? totalSummary("weight")
    : goals[c] ? `${goalsMetCount(c)}× goal met` : `${activeDaySet(c).size} active days`;
  return `
    <button class="tile-card" data-cat="${c}">
      <span class="tile-head">
        ${categoryIconHTML(c, 30)}
        <span><span class="tile-name">${CATEGORIES[c].title}</span><br><span class="tile-detail">${detail}</span></span>
        ${streak > 0 ? `<span class="tile-streak">${streak}d streak</span>` : ""}
      </span>
      <span class="tile-grid">${grid}</span>
    </button>`;
}

function renderProgress() {
  const filter = progressFilter;
  const buckets = dayBuckets(filter);
  const tKey = todayKey();
  const weeks = weeksFor(WEEKS_TO_SHOW);

  const monthLabels = weeks.map((week, i) => {
    if (i === 0) {
      const next = weeks[1]?.[0];
      const label = next && keyToDate(next).getMonth() === keyToDate(week[0]).getMonth();
      return label ? monthShortFmt.format(keyToDate(week[0])) : "";
    }
    const prev = keyToDate(weeks[i - 1][0]).getMonth();
    const cur = keyToDate(week[0]).getMonth();
    return prev !== cur ? monthShortFmt.format(keyToDate(week[0])) : "";
  });

  const grid = weeks.map((week) => `
    <div class="heat-col">
      ${week.map((k) => {
        if (k > tKey) return `<span class="heat-cell empty" style="visibility:hidden"></span>`;
        const level = levelFor(buckets.get(k) ?? [], filter);
        return `<span class="heat-cell l${level}" title="${k}"></span>`;
      }).join("")}
    </div>`).join("");

  const totalLabel = filter === "weight" ? "Latest weight" : filter ? "Total logged" : "Total entries";
  const goalNote = filter && filter !== "weight" && goals[filter]
    ? `<span class="legend-text">· full = goal met</span>` : "";
  const legend = filter === "weight"
    ? `<span class="heat-cell l4"></span><span class="legend-text">Logged</span>`
    : `<span class="legend-text">Less</span>${[0, 1, 2, 3, 4].map((l) => `<span class="heat-cell l${l}"></span>`).join("")}<span class="legend-text">More</span>${goalNote}`;

  const thirdTile = filter && filter !== "weight" && goals[filter]
    ? `<div class="stat-tile"><div class="stat-value">${goalsMetCount(filter)} <span class="stat-suffix">days</span></div><div class="stat-label">Goals met</div></div>`
    : `<div class="stat-tile"><div class="stat-value">${activeDaySet(filter).size}</div><div class="stat-label">Active days</div></div>`;

  main.innerHTML = `
    <h1 class="page-title">Progress</h1>
    <div class="chips">${chipRowHTML(filter)}</div>
    <div class="stat-grid">
      <div class="stat-tile"><div class="stat-value">${currentStreak(filter)} <span class="stat-suffix">days</span></div><div class="stat-label">Current streak</div></div>
      <div class="stat-tile"><div class="stat-value">${bestStreak(filter)} <span class="stat-suffix">days</span></div><div class="stat-label">Best streak</div></div>
      ${thirdTile}
      <div class="stat-tile"><div class="stat-value">${totalSummary(filter)}</div><div class="stat-label">${totalLabel}</div></div>
    </div>
    <div class="heat-card">
      <div class="heat-scroll" id="heat-scroll">
        <div class="heat-months">${monthLabels.map((l) => `<span>${l}</span>`).join("")}</div>
        <div class="heat-grid">${grid}</div>
      </div>
      <div class="heat-legend">${legend}</div>
    </div>
    ${filter == null ? `
      <h2 class="section-title">By Category</h2>
      ${CATEGORY_KEYS.map(categoryTileHTML).join("")}` : ""}`;

  main.querySelectorAll(".chip").forEach((chip) =>
    chip.addEventListener("click", () => {
      progressFilter = chip.dataset.filter || null;
      renderProgress();
    }));
  main.querySelectorAll(".tile-card").forEach((tile) =>
    tile.addEventListener("click", () => {
      progressFilter = tile.dataset.cat;
      renderProgress();
    }));
  const scroll = $("#heat-scroll");
  scroll.scrollLeft = scroll.scrollWidth;
}

/* ---------- tab bar, day rollover, cross-tab sync ---------- */

document.querySelectorAll("#tabbar button").forEach((btn) =>
  btn.addEventListener("click", () => { currentTab = btn.dataset.tab; render(); }));

let lastDay = todayKey();
function checkDayRollover() {
  if (todayKey() !== lastDay) {
    lastDay = todayKey();
    render();
  }
}
setInterval(checkDayRollover, 30000);
document.addEventListener("visibilitychange", () => { if (!document.hidden) checkDayRollover(); });

window.addEventListener("storage", (event) => {
  if (event.key === ACCOUNT_KEY || event.key === null) {
    refreshPersistedAccount();
    refreshAccountDialog();
  }
  if ([DOCUMENT_KEY, null].includes(event.key)) {
    try { adoptDoc(documentStore.read()); } catch (error) { storageFailure(error); return; }
    syncController.mutated();
    render();
  }
});

/* ---------- demo seeding (mirrors the Swift SeededGenerator flow) ---------- */

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function seedDemoDoc(doc) {
  if (location.hash !== "#demo" || doc.entries.length !== 0) return doc;
  const rand = mulberry32(42);
  const randInt = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));
  const seeded = [];
  for (let offset = 0; offset < 120; offset++) {
    const day = keyToDate(addDays(todayKey(), -offset));
    const at = (h) => { const d = new Date(day); d.setHours(h, 0, 0, 0); return d.toISOString(); };
    if (rand() < 0.75) seeded.push({ id: newId(), date: at(9), category: "study", kind: "duration", amount: randInt(2, 10) * 15 * 60 });
    if (rand() < 0.5) seeded.push({ id: newId(), date: at(18), category: "gym", kind: "duration", amount: randInt(3, 6) * 15 * 60 });
    if (rand() < 0.4) seeded.push({ id: newId(), date: at(7), category: "cardio", kind: "number", amount: randInt(1, 3) });
    if (rand() < 0.3) seeded.push({ id: newId(), date: at(8), category: "weight", kind: "number", amount: 72 + randInt(-20, 20) / 10 });
  }
  const result = { ...doc, entries: seeded };
  if (!Object.keys(doc.goals).length) {
    result.goals = {
      study: { kind: "duration", amount: 2 * 3600 },
      gym: { kind: "duration", amount: 45 * 60 },
      cardio: { kind: "number", amount: 2 },
      weight: { kind: "number", amount: 70 },
    };
    result.goalsUpdatedAt = new Date().toISOString();
  }
  return result;
}

/* ---------- boot ---------- */

async function boot() {
  try {
    adoptDoc(await documentStore.update(seedDemoDoc));
    render();
    if (account) syncNow();
  } catch (error) {
    $("#main").textContent = `Tracking data could not be loaded. ${error.message || error}`;
  }
}
boot();
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && account) syncNow();
});

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js").catch(() => {});
}
