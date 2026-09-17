import test from "node:test";
import assert from "node:assert/strict";
import { createServer, request as httpRequest } from "node:http";
import { webcrypto } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runInNewContext } from "node:vm";
import { createRequestHandler } from "../MarsMomentumServer/server.mjs";
import { createSyncController, mergeDocs, newId } from "../MarsMomentumWeb/sync-core.mjs";
import { createDocumentStore } from "../MarsMomentumWeb/document-store.mjs";

const uuid = "a08877a0-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const uuid2 = "b08877a0-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const doc = (entries = []) => ({ entries, tombstones: [], goals: {}, goalsUpdatedAt: null });
const entry = (id = uuid) => ({ id, date: "2026-09-14T08:00:00.125Z", category: "study", kind: "duration", amount: 3600 });
const deferred = () => {
  let resolve;
  const promise = new Promise(r => { resolve = r; });
  return { promise, resolve };
};

async function fixture(t) {
  const dataDir = await mkdtemp(join(tmpdir(), "mars-sync-test-"));
  const handler = createRequestHandler({ dataDir });
  let onSlowRequest = () => {};
  const server = createServer((req, res) => {
    void handler(req, res);
    // The async handler has reached readBody before returning its promise.
    if (req.headers["x-test-slow"]) onSlowRequest();
  });
  t.after(async () => {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    await rm(dataDir, { recursive: true, force: true });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const port = server.address().port;
  function call(path, { method = "POST", body = {}, token, headers = {}, slow = false } = {}) {
    const json = JSON.stringify(body);
    let req;
    const response = new Promise((resolve, reject) => {
      req = httpRequest({ hostname: "127.0.0.1", port, path, method, headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}`, "X-Mars-User": "tester" } : {}),
        ...headers,
      } }, res => {
        let raw = "";
        res.setEncoding("utf8");
        res.on("data", chunk => { raw += chunk; });
        res.on("end", () => {
          let data;
          try { data = JSON.parse(raw); } catch { data = raw; }
          resolve({ status: res.statusCode, data, headers: res.headers });
        });
      });
      req.on("error", reject);
      if (slow) req.write(json.slice(0, -1));
      else req.end(method === "GET" ? undefined : json);
    });
    return slow ? { response, finish: () => req.end(json.slice(-1)) } : response;
  }
  const account = await call("/api/register", { body: { username: "tester", password: "test-only-password" } });
  assert.equal(account.status, 201);
  return { call, token: account.data.token, dataDir, slowStarted() {
    const signal = deferred();
    onSlowRequest = signal.resolve;
    return signal.promise;
  } };
}

test("overlapping sync bodies retain both devices' entries", async t => {
  const f = await fixture(t);
  const started = f.slowStarted();
  const slow = f.call("/api/sync", { token: f.token, body: doc([entry()]), slow: true, headers: { "X-Test-Slow": "1" } });
  await started;
  assert.equal((await f.call("/api/sync", { token: f.token, body: doc([entry(uuid2)]) })).status, 200);
  slow.finish();
  const merged = await slow.response;
  assert.equal(merged.status, 200);
  assert.deepEqual(new Set(merged.data.entries.map(e => e.id)), new Set([uuid, uuid2]));
  const stored = await f.call("/api/data", { method: "GET", token: f.token });
  assert.equal(stored.data.entries.length, 2);
});

test("logout during a slow sync revokes the request and stays revoked", async t => {
  const f = await fixture(t);
  const started = f.slowStarted();
  const slow = f.call("/api/sync", { token: f.token, body: doc([entry()]), slow: true, headers: { "X-Test-Slow": "1" } });
  await started;
  assert.equal((await f.call("/api/logout", { token: f.token })).status, 200);
  slow.finish();
  assert.equal((await slow.response).status, 401);
  assert.equal((await f.call("/api/data", { method: "GET", token: f.token })).status, 401);
  const stored = JSON.parse(await readFile(join(f.dataDir, "users/tester.json"), "utf8"));
  assert.equal(stored.tokens.length, 0);
  assert.equal(stored.doc.entries.length, 0);
});

test("login during a slow sync does not lose the newly issued token", async t => {
  const f = await fixture(t);
  const started = f.slowStarted();
  const slow = f.call("/api/sync", { token: f.token, body: doc([entry()]), slow: true, headers: { "X-Test-Slow": "1" } });
  await started;
  const login = await f.call("/api/login", { body: { username: "tester", password: "test-only-password" } });
  slow.finish();
  assert.equal((await slow.response).status, 200);
  assert.equal((await f.call("/api/data", { method: "GET", token: login.data.token })).status, 200);
});

test("malformed Host and URL inputs do not terminate the server", async t => {
  const f = await fixture(t);
  assert.equal((await f.call("/api/health", { method: "GET", headers: { Host: "[" } })).status, 200);
  assert.equal((await f.call("http://[", { method: "GET" })).status, 400);
  assert.equal((await f.call("/api/health", { method: "GET" })).status, 200);
});

test("legacy stored IDs migrate consistently and old clients can still delete them", async t => {
  const f = await fixture(t);
  const file = join(f.dataDir, "users/tester.json");
  const stored = JSON.parse(await readFile(file, "utf8"));
  stored.doc = doc([entry("legacy-browser-entry")]);
  await writeFile(file, JSON.stringify(stored));
  const migrated = (await f.call("/api/data", { method: "GET", token: f.token })).data;
  assert.match(migrated.entries[0].id, /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/);
  assert.equal(migrated.idMappings["legacy-browser-entry"], migrated.entries[0].id);
  const again = (await f.call("/api/sync", { token: f.token, body: doc([entry("legacy-browser-entry")]) })).data;
  assert.equal(again.entries.length, 1);
  assert.equal(again.entries[0].id, migrated.entries[0].id);
  const deleted = (await f.call("/api/sync", { token: f.token, body: { ...doc(), tombstones: [{ id: "legacy-browser-entry", deletedAt: null }] } })).data;
  assert.equal(deleted.entries.length, 0);
  assert.equal(deleted.tombstones[0].id, migrated.entries[0].id);
});

test("UUID case is ignored and fractional goal timestamps choose the later edit", async t => {
  const f = await fixture(t);
  const earlier = { ...doc([entry(uuid.toUpperCase())]), goals: { study: { kind: "duration", amount: 3600 } }, goalsUpdatedAt: "2026-09-14T08:00:00.100Z" };
  await f.call("/api/sync", { token: f.token, body: earlier });
  const later = { ...earlier, entries: [entry()], goals: { study: { kind: "duration", amount: 7200 } }, goalsUpdatedAt: "2026-09-14T08:00:00.900Z" };
  const merged = (await f.call("/api/sync", { token: f.token, body: later })).data;
  assert.equal(merged.entries.length, 1);
  assert.equal(merged.goals.study.amount, 7200);
  assert.equal(merged.goalsUpdatedAt, later.goalsUpdatedAt);
});

test("oversized record lists reject the whole document without replacing data", async t => {
  const f = await fixture(t);
  await f.call("/api/sync", { token: f.token, body: doc([entry()]) });
  const tooMany = { ...doc(), tombstones: Array.from({ length: 100001 }, () => ({ id: "x" })) };
  assert.equal((await f.call("/api/sync", { token: f.token, body: tooMany })).status, 400);
  assert.equal((await f.call("/api/data", { method: "GET", token: f.token })).data.entries.length, 1);
});

test("the server serves the browser sync module with a JavaScript MIME type", async t => {
  const f = await fixture(t);
  const response = await f.call("/sync-core.mjs", { method: "GET" });
  assert.equal(response.status, 200);
  assert.match(response.headers["content-type"], /javascript/);
});

test("login rejects oversized invalid usernames before allocating limiter state", async t => {
  const f = await fixture(t);
  for (let i = 0; i < 12; i++) {
    const result = await f.call("/api/login", { body: { username: "x".repeat(1024 * 1024) + i, password: "wrong" } });
    assert.equal(result.status, 400);
  }
  assert.equal((await f.call("/api/login", { body: { username: "tester", password: "test-only-password" } })).status, 200);
});

test("login limiter caps retained names without evicting active lockouts, then expires them", async () => {
  let now = 0;
  const source = (await readFile(new URL("../MarsMomentumServer/server.mjs", import.meta.url), "utf8"))
    .split("/* ---------- login rate limiting ---------- */")[1]
    .split("/* ---------- doc validation & merge ---------- */")[0];
  const context = { MAX_LOGIN_SLOTS: 2, Date: { now: () => now } };
  runInNewContext(source + "\nglobalThis.limited = rateLimited; globalThis.slotCount = () => attempts.size;", context);
  for (let i = 0; i < 10; i++) assert.equal(context.limited("target"), false);
  assert.equal(context.limited("target"), true);
  assert.equal(context.limited("other"), false);
  assert.equal(context.limited("overflow"), true);
  assert.equal(context.limited("target"), true);
  assert.equal(context.slotCount(), 2);
  now = 15 * 60 * 1000;
  assert.equal(context.limited("fresh"), false);
  assert.equal(context.slotCount(), 1);
});

test("UUID fallback remains compatible with Swift UUID parsing", () => {
  const random = { getRandomValues: array => webcrypto.getRandomValues(array) };
  const ids = Array.from({ length: 100 }, () => newId(random));
  for (const id of ids) assert.match(id, /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/);
  assert.equal(new Set(ids).size, 100);
});

test("client merge keeps in-flight additions, deletions and goal edits", () => {
  const remote = { ...doc([entry()]), goals: { study: { kind: "number", amount: 1 } }, goalsUpdatedAt: "2026-09-14T08:00:00.900Z" };
  const local = { ...doc([entry(uuid2)]), tombstones: [{ id: uuid, deletedAt: null }], goals: {}, goalsUpdatedAt: "2026-09-14T08:00:00.100Z" };
  const merged = mergeDocs(remote, local, true);
  assert.deepEqual(merged.entries.map(e => e.id), [uuid2]);
  assert.deepEqual(merged.goals, {});
  assert.equal(merged.tombstones[0].id, uuid);
});

test("client merge remaps a deletion made during legacy ID migration", () => {
  const remote = { ...doc([entry()]), idMappings: { legacy: uuid } };
  const local = { ...doc(), tombstones: [{ id: "legacy", deletedAt: null }] };
  const merged = mergeDocs(remote, local);
  assert.equal(merged.entries.length, 0);
  assert.equal(merged.tombstones[0].id, uuid);
});

test("sync controller drains edits made while the first request is pending", async () => {
  let local = doc([entry()]);
  const first = deferred();
  const requests = [];
  let synced = 0;
  const controller = createSyncController({
    readDoc: () => local,
    applyDoc: value => { local = value; },
    request: async value => { requests.push(value); return requests.length === 1 ? first.promise : value; },
    onSynced: () => { synced += 1; },
  });
  controller.setAccount({ username: "first" });
  const running = controller.sync();
  local = { ...doc([entry(uuid2)]), tombstones: [{ id: uuid, deletedAt: null }], goals: { gym: { kind: "number", amount: 2 } }, goalsUpdatedAt: "2026-09-14T08:00:00.999Z" };
  controller.mutated();
  first.resolve(requests[0]);
  await running;
  assert.equal(requests.length, 2);
  assert.deepEqual(requests[1].entries.map(e => e.id), [uuid2]);
  assert.equal(requests[1].tombstones[0].id, uuid);
  assert.equal(requests[1].goals.gym.amount, 2);
  assert.equal(synced, 1);
});

test("late replies from a signed-out account cannot change a new session", async () => {
  let local = doc();
  const oldReply = deferred();
  const states = [];
  let synced = 0;
  const controller = createSyncController({
    readDoc: () => local, applyDoc: value => { local = value; },
    request: async (_, account) => account.username === "old" ? oldReply.promise : doc([entry(uuid2)]),
    onState: value => states.push(value), onSynced: () => { synced += 1; },
  });
  controller.setAccount({ username: "old" });
  const oldRequest = controller.sync();
  controller.setAccount(null);
  controller.setAccount({ username: "new" });
  await controller.sync();
  oldReply.resolve(doc([entry()]));
  await oldRequest;
  assert.deepEqual(local.entries.map(e => e.id), [uuid2]);
  assert.equal(synced, 1);
  assert.equal(states.at(-1), "idle");
});

test("a failed sync can be retried", async () => {
  let attempt = 0;
  const states = [];
  const controller = createSyncController({
    readDoc: () => doc(), applyDoc: () => {}, onState: state => states.push(state),
    request: async value => { if (++attempt === 1) throw new Error("offline"); return value; },
  });
  controller.setAccount({ username: "tester" });
  await controller.sync();
  assert.equal(states.at(-1), "offline");
  await controller.sync();
  assert.equal(attempt, 2);
  assert.equal(states.at(-1), "idle");
});

function storageFixture(initial = {}) {
  const values = new Map(Object.entries(initial));
  let pending = Promise.resolve();
  return {
    values,
    storage: { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key) },
    lock: action => { const next = pending.then(action); pending = next.catch(() => {}); return next; },
  };
}

async function appFixture(shared, extra = {}) {
  const fullSource = await readFile(new URL("../MarsMomentumWeb/app.js", import.meta.url), "utf8");
  const source = fullSource.replace(/^import .*\n/gm, "").split("/* ---------- queries (mirror EntryStore) ---------- */")[0];
  const context = {
    localStorage: shared.storage, navigator: { language: "en-GB" }, URL, setTimeout, clearTimeout,
    createDocumentStore, createStorageLock: () => shared.lock, newId, createSyncController, mergeDocs,
    window: { alert: message => { throw new Error(message); } }, ...extra,
  };
  runInNewContext(`${source}\nfunction refreshAccountDialog() {}\nfunction render() {}\n` +
    `globalThis.app = { addEntry, deleteEntry, currentDoc, applyDoc, syncController,
      initialize: async () => adoptDoc(await documentStore.update(doc => doc)) };`, context);
  await context.app.initialize();
  return { ...context, fullSource };
}

test("two offline tabs retain additions and deletion tombstones before storage events arrive", async () => {
  const shared = storageFixture({ "mars-entries": JSON.stringify([entry()]) });
  const a = await appFixture(shared), b = await appFixture(shared);
  await Promise.all([
    a.app.addEntry("study", "number", 2, "2026-09-14"),
    b.app.addEntry("gym", "number", 3, "2026-09-14"),
  ]);
  assert.equal(JSON.parse(shared.values.get("mars-document-v1")).entries.length, 3);
  await Promise.all([a.app.deleteEntry(uuid), b.app.applyDoc(doc([entry()]))]);
  const saved = JSON.parse(shared.values.get("mars-document-v1"));
  assert.equal(saved.entries.length, 2);
  assert.equal(saved.entries.some(e => e.id === uuid), false);
  assert.equal(saved.tombstones[0].id, uuid);
});

test("cross-tab signout rejects an old sync reply before a storage event arrives", async () => {
  const credentials = { server: "http://example.test", username: "old", token: "test-token" };
  const shared = storageFixture({ "mars-account": JSON.stringify(credentials) });
  const reply = deferred();
  const tab = await appFixture(shared, { fetch: () => reply.promise });
  const running = tab.app.syncController.sync();
  await shared.lock(() => shared.storage.removeItem("mars-account"));
  reply.resolve({ ok: true, json: async () => doc([entry()]) });
  await running;
  assert.equal(JSON.parse(shared.values.get("mars-document-v1")).entries.length, 0);
  assert.equal(shared.storage.getItem("mars-last-sync"), null);
});

test("failed persistence rejects an edit without changing the visible or saved document", async () => {
  const shared = storageFixture();
  const tab = await appFixture(shared);
  shared.storage.setItem = () => { throw new Error("Quota exceeded"); };
  await assert.rejects(tab.app.addEntry("study", "number", 2, "2026-09-14"), /Quota exceeded/);
  assert.equal(tab.app.currentDoc().entries.length, 0);
  assert.equal(JSON.parse(shared.values.get("mars-document-v1")).entries.length, 0);
});

test("other-tab entry changes keep the goal editor open and untouched exact goals survive Save", async () => {
  const shared = storageFixture({ "mars-goals": JSON.stringify({ study: { kind: "duration", amount: 14 * 3600 + 15 * 60 } }) });
  const controls = (value, type = "select") => ({ value, type, checked: false, addEventListener() {} });
  const rows = ["study", "gym", "cardio", "weight"].map(cat => {
    const fields = {
      ".goal-on": controls("", "checkbox"), ".goal-kind": controls("duration"),
      ".goal-h": controls("0"), ".goal-m": controls(cat === "study" ? "15" : "0"),
      ".goal-n": controls("", "number"), ".goal-fields": {}, ".goal-duration": {},
    };
    fields[".goal-on"].checked = cat === "study";
    return { dataset: { cat }, querySelector: selector => fields[selector],
      querySelectorAll: () => Object.values(fields).filter(value => value.type) };
  });
  let submit;
  let storageChanged;
  const saveButton = { disabled: false };
  const dialog = {
    open: false, querySelectorAll: () => rows,
    showModal() { this.open = true; }, close() { this.open = false; },
    querySelector: selector => selector === ".goals-form" ? { addEventListener: (_, handler) => { submit = handler; } }
      : selector === '[type="submit"]' ? saveButton : { addEventListener() {} },
  };
  const tab = await appFixture(shared, { document: { querySelector: () => dialog } });
  const goalSource = tab.fullSource.split("/* ----- goals dialog ----- */")[1].split("/* ----- account dialog ----- */")[0];
  const storageSource = 'window.addEventListener("storage",' + tab.fullSource.split('window.addEventListener("storage",')[1]
    .split("/* ---------- demo seeding")[0];
  // The app fixture's closures retain their original context; expose its goal
  // dialog in the same context rather than duplicating the goal-saving logic.
  const prefix = tab.fullSource.replace(/^import .*\n/gm, "").split("/* ---------- queries (mirror EntryStore) ---------- */")[0];
  const context = { ...tab, document: { querySelector: () => dialog },
    window: { ...tab.window, addEventListener: (_, handler) => { storageChanged = handler; } } };
  runInNewContext(`${prefix}\nfunction refreshAccountDialog() {}\nfunction render() {}\n${goalSource}\n${storageSource}\nopenGoalsDialog();`, context);
  const otherTab = await appFixture(shared);
  await otherTab.app.addEntry("gym", "number", 1, "2026-09-14");
  storageChanged({ key: "mars-document-v1" });
  assert.equal(dialog.open, true);
  assert.equal(rows[0].querySelector(".goal-m").value, "15");
  await submit({ preventDefault() {} });
  assert.equal(JSON.parse(shared.values.get("mars-document-v1")).goals.study.amount, 14 * 3600 + 15 * 60);
  assert.equal(JSON.parse(shared.values.get("mars-document-v1")).entries.length, 1);
});

test("editing one duration picker preserves the exact loaded value of the other", async () => {
  for (const scenario of [
    { amount: 3600 + 10 * 60, field: ".goal-h", value: "2", expected: 7200 + 10 * 60 },
    { amount: 14 * 3600 + 15 * 60, field: ".goal-m", value: "30", expected: 14 * 3600 + 30 * 60 },
    { amount: 3600 + 90, field: ".goal-h", value: "2", expected: 7200 + 90 },
  ]) {
    const shared = storageFixture({ "mars-goals": JSON.stringify({ study: { kind: "duration", amount: scenario.amount } }) });
    const control = (type = "select") => ({ type, value: "", checked: false, addEventListener() {} });
    const rows = ["study", "gym", "cardio", "weight"].map(cat => {
      const fields = {
        ".goal-on": control("checkbox"), ".goal-kind": control(),
        ".goal-h": control(), ".goal-m": control(), ".goal-n": control("number"),
      };
      fields[".goal-on"].checked = cat === "study";
      fields[".goal-kind"].value = "duration";
      return { dataset: { cat }, querySelector: selector => fields[selector], querySelectorAll: () => Object.values(fields) };
    });
    let submit;
    const saveButton = { disabled: false };
    const dialog = {
      set innerHTML(html) {
        // Read the generated options using the browser's first-option fallback
        // when no option is selected, so missing loaded values fail this test.
        for (const fieldset of html.matchAll(/<fieldset[^>]*data-cat="([^"]+)"[^>]*>([\s\S]*?)<\/fieldset>/g)) {
          const row = rows.find(value => value.dataset.cat === fieldset[1]);
          for (const select of fieldset[2].matchAll(/<select class="(goal-[hm])">([\s\S]*?)<\/select>/g)) {
            const options = [...select[2].matchAll(/<option value="([^"]+)"([^>]*)>/g)];
            row.querySelector(`.${select[1]}`).value = (options.find(option => /\bselected\b/.test(option[2])) || options[0])[1];
          }
        }
      },
      querySelectorAll: () => rows, showModal() {}, close() {},
      querySelector: selector => selector === ".goals-form" ? { addEventListener: (_, handler) => { submit = handler; } }
        : selector === '[type="submit"]' ? saveButton : { addEventListener() {} },
    };
    const tab = await appFixture(shared, { document: { querySelector: () => dialog } });
    const prefix = tab.fullSource.replace(/^import .*\n/gm, "").split("/* ---------- queries (mirror EntryStore) ---------- */")[0];
    const goalSource = tab.fullSource.split("/* ----- goals dialog ----- */")[1].split("/* ----- account dialog ----- */")[0];
    runInNewContext(`${prefix}\nfunction refreshAccountDialog() {}\nfunction render() {}\n${goalSource}\nopenGoalsDialog();`, tab);
    assert.equal(Number(rows[0].querySelector(".goal-h").value), Math.floor(scenario.amount / 3600));
    assert.equal(Number(rows[0].querySelector(".goal-m").value), (scenario.amount % 3600) / 60);
    rows[0].querySelector(scenario.field).value = scenario.value;
    await submit({ preventDefault() {} });
    assert.equal(JSON.parse(shared.values.get("mars-document-v1")).goals.study.amount, scenario.expected);
  }
});

test("goals saved in a different key order settle in a single sync request", async () => {
  const credentials = { server: "http://example.test", username: "tester", token: "test-token" };
  // Earlier builds stored goals in the order they were saved (here a target
  // weight before a study goal), while the app holds goals in category order.
  const goals = { weight: { kind: "number", amount: 70 }, study: { kind: "duration", amount: 3600 } };
  const shared = storageFixture({
    "mars-account": JSON.stringify(credentials),
    "mars-document-v1": JSON.stringify({ ...doc(), goals, goalsUpdatedAt: "2026-09-14T08:00:00.000Z" }),
  });
  let requests = 0;
  const tab = await appFixture(shared, { fetch: async (_, options) => {
    requests += 1;
    if (requests > 5) throw new Error("sync did not settle");
    return { ok: true, json: async () => JSON.parse(options.body) };
  } });
  await tab.app.syncController.sync();
  assert.equal(requests, 1);
  assert.deepEqual(JSON.parse(shared.values.get("mars-document-v1")).goals, goals);
  assert.notEqual(shared.storage.getItem("mars-last-sync"), null);
});

test("service worker activation removes only this app's stale caches", async () => {
  const handlers = {};
  const deleted = [];
  runInNewContext(await readFile(new URL("../MarsMomentumWeb/sw.js", import.meta.url), "utf8"), {
    self: { addEventListener: (name, handler) => { handlers[name] = handler; }, clients: { claim: async () => {} } },
    caches: { keys: async () => ["mars-tracking-v1", "mars-tracking-v13", "mars-addict-v1", "other-app"], delete: async key => deleted.push(key) },
  });
  let completion;
  handlers.activate({ waitUntil: value => { completion = value; } });
  await completion;
  assert.deepEqual(deleted, ["mars-tracking-v1"]);
});
