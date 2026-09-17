const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { randomUUID } = require('node:crypto');
const test = require('node:test');
const { createStorageLock } = require('../MarsFocusWeb/storage-lock.js');
const source = fs.readFileSync(path.join(__dirname, '../MarsFocusWeb/app.js'), 'utf8');

// Model the browser's shared, exclusive readwrite transaction queue. Separate
// page contexts share storage but receive no storage events during these tests.
function sharedBrowser(initial = {}) {
  const values = new Map(Object.entries(initial).map(([key, value]) => [key, JSON.stringify(value)]));
  const databases = new Map();
  const indexedDB = { open(name) {
    const request = {};
    setImmediate(() => {
      if (!databases.has(name)) {
        const queue = [];
        let busy = false;
        const drain = () => {
          if (busy || !queue.length) return;
          busy = true;
          const tx = queue.shift();
          setImmediate(() => {
            tx.request?.onsuccess?.();
            setImmediate(() => {
              if (tx.aborted) tx.onabort?.(); else tx.oncomplete?.();
              busy = false;
              drain();
            });
          });
        };
        databases.set(name, {
          createObjectStore() {}, close() {},
          transaction(store, mode) {
            assert.equal(store, 'mutex'); assert.equal(mode, 'readwrite');
            const tx = {
              abort() { this.aborted = true; },
              objectStore() { return { get() { tx.request = {}; return tx.request; } }; },
            };
            queue.push(tx); drain(); return tx;
          },
        });
        request.result = databases.get(name); request.onupgradeneeded?.();
      }
      request.result = databases.get(name); request.onsuccess?.();
    });
    return request;
  } };
  return { indexedDB, values, localStorage: {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  }, state: () => JSON.parse(values.get('tom-state-v1')) };
}

function documentStub() {
  const elements = new Map();
  class Element {
    constructor(id) { this.id = id; this.value = ''; this.listeners = new Map(); this.children = []; this.dataset = {}; this.classList = { toggle() {} }; }
    addEventListener(type, listener) { this.listeners.set(type, listener); }
    dispatch(type) { return this.listeners.get(type)?.({ target: this, key: '', preventDefault() {} }); }
    set innerHTML(html) {
      this.html = html;
      for (const id of this.children) elements.delete(id);
      this.children = [...html.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
      for (const id of this.children) elements.set(id, new Element(id));
    }
    get innerHTML() { return this.html || ''; }
    querySelector() { return null; }
    querySelectorAll() { return []; }
    setAttribute(name, value) { this[name] = value; }
    showModal() {}
    close() { this.dispatch('close'); }
  }
  for (const id of ['main', 'dlg-start', 'dlg-blocklist', 'dlg-rule', 'dlg-settings', 'dlg-day', 'dlg-pomodoro']) elements.set(id, new Element(id));
  return { querySelector: (selector) => elements.get(selector.slice(1)) || null, querySelectorAll: () => [], addEventListener() {} };
}

async function page(browser, fetch = async () => { throw new Error('Offline'); }) {
  const document = documentStub(), alerts = [];
  const context = vm.createContext({
    console, Date, Math, Set, Map, Promise, JSON, String, Number, Object, Array,
    document, navigator: {}, location: { protocol: 'http:', hash: '' },
    window: { addEventListener() {} }, crypto: { randomUUID },
    localStorage: browser.localStorage,
    createStorageLock: (name) => createStorageLock(name, browser.indexedDB),
    setInterval() {}, fetch, alert: (message) => alerts.push(message), confirm: () => true,
  });
  vm.runInContext(source, context);
  const run = (code) => vm.runInContext(code, context);
  await run('ready');
  await run('tick()');
  return { run, document, alerts };
}

const list = { id: 'legacy-list', name: 'Original', appIDs: [], websites: ['example.test'], keywords: [] };
const legacy = () => ({
  'tom-blocklists': [list],
  'tom-sessions': { history: [{ id: 'existing', startedAt: '2026-01-01T09:00:00Z', endedAt: '2026-01-01T09:30:00Z', blocklistNames: ['Original'] }] },
  'tom-coach': { provider: 'gemini', keys: { gemini: 'test-key' } },
});

test('two first launches migrate legacy data once and remove only the old credential copy', async () => {
  const browser = sharedBrowser(legacy());
  const originals = new Map(browser.values);
  await Promise.all([page(browser), page(browser)]);
  assert.equal(browser.state().sessions.history[0].id, 'existing');
  assert.equal(browser.state().blocklists[0].id, 'legacy-list');
  assert.equal(browser.state().coach.keys.gemini, 'test-key');
  for (const [key, value] of originals) {
    if (key !== 'tom-coach') assert.equal(browser.values.get(key), value);
  }
  assert.equal(browser.values.has('tom-coach'), false);
});

test('already migrated storage removes a leftover credential without restoring a cleared key', async () => {
  const browser = sharedBrowser(legacy());
  browser.values.set('tom-state-v1', JSON.stringify({
    blocklists: [list], sessions: {}, coach: { provider: 'gemini', keys: {} },
  }));
  await page(browser);
  assert.deepEqual(browser.state().coach.keys, {});
  assert.equal(browser.values.has('tom-coach'), false);
});

test('failed migration preserves the only saved copy of a provider credential', async () => {
  const browser = sharedBrowser(legacy());
  const oldCredential = browser.values.get('tom-coach');
  browser.localStorage.setItem = () => { throw new Error('Quota exceeded'); };
  const a = await page(browser);
  assert.equal(browser.values.has('tom-state-v1'), false);
  assert.equal(browser.values.get('tom-coach'), oldCredential);
  assert.match(a.alerts[0], /Quota exceeded/);
});

test('concurrent scheduling from stale pages preserves both sessions and history', async () => {
  const browser = sharedBrowser(legacy());
  const [a, b] = await Promise.all([page(browser), page(browser)]);
  await Promise.all([
    a.run('scheduleSession(new Date(Date.now() + 3600000), 25, ["legacy-list"], false)'),
    b.run('scheduleSession(new Date(Date.now() + 7200000), 45, ["legacy-list"], true)'),
  ]);
  assert.deepEqual(browser.state().sessions.scheduled.map((s) => s.minutes), [25, 45]);
  assert.equal(browser.state().sessions.history.length, 1);
});

test('concurrent starts cannot overwrite an already active session', async () => {
  const browser = sharedBrowser(legacy());
  const [a, b] = await Promise.all([page(browser), page(browser)]);
  const results = await Promise.all([
    a.run('startSession(["legacy-list"], 25, false)'),
    b.run('startSession(["legacy-list"], 45, false)'),
  ]);
  assert.equal(results.filter(Boolean).length, 1, JSON.stringify({ results, alerts: [a.alerts, b.alerts] }));
  const active = browser.state().sessions.active;
  assert.equal((new Date(active.endsAt) - new Date(active.startedAt)) / 60000, 25);
});

test('two timer completions produce one record and preserve another page queue', async () => {
  const browser = sharedBrowser(legacy());
  const [a, b] = await Promise.all([page(browser), page(browser)]);
  await a.run('mutateState(() => { S.active = { id: "expired", startedAt: new Date(Date.now() - 60000).toISOString(), endsAt: new Date(Date.now() - 1000).toISOString(), blocklistIDs: ["legacy-list"], blocklistNames: ["Original"] }; })');
  await Promise.all([
    a.run('tick()'), b.run('tick()'),
    b.run('scheduleSession(new Date(Date.now() + 3600000), 25, ["legacy-list"], false)'),
  ]);
  assert.equal(browser.state().sessions.history.length, 2);
  assert.equal(browser.state().sessions.scheduled.length, 1);
  assert.equal(browser.state().sessions.active, null);
});

test('a stale blocklist editor cannot resurrect a list deleted in another page', async () => {
  const browser = sharedBrowser(legacy());
  const [a, b] = await Promise.all([page(browser), page(browser)]);
  a.run('openBlocklistEditor(blocklists[0])');
  a.document.querySelector('#be-name').value = 'Edited';
  await b.run('mutateState(() => { blocklists = []; })');
  await a.document.querySelector('#be-save').dispatch('click');
  assert.deepEqual(browser.state().blocklists, []);
  assert.match(a.alerts[0], /deleted or locked/);
});

test('simultaneous list editors keep both newly saved lists', async () => {
  const browser = sharedBrowser(legacy());
  const [a, b] = await Promise.all([page(browser), page(browser)]);
  a.run('openBlocklistEditor(null)');
  b.run('openBlocklistEditor(null)');
  a.document.querySelector('#be-name').value = 'First new list';
  b.document.querySelector('#be-name').value = 'Second new list';
  await Promise.all([
    a.document.querySelector('#be-save').dispatch('click'),
    b.document.querySelector('#be-save').dispatch('click'),
  ]);
  assert.deepEqual(browser.state().blocklists.map((b) => b.name), ['Original', 'First new list', 'Second new list']);
});

test('provider key edits preserve another provider updated in a different page', async () => {
  const browser = sharedBrowser(legacy());
  const [a, b] = await Promise.all([page(browser), page(browser)]);
  a.run('openSettings()');
  await b.run('mutateState(() => { coachCfg.provider = "claude"; })');
  b.run('openSettings()');
  const gemini = a.document.querySelector('#st-key');
  const claude = b.document.querySelector('#st-key');
  gemini.value = 'updated-gemini'; claude.value = 'new-claude';
  gemini.dispatch('input'); claude.dispatch('input');
  await b.run('mutateState(() => {})');
  assert.deepEqual(browser.state().coach.keys, { gemini: 'updated-gemini', claude: 'new-claude' });
});

test('storage failure preserves saved data and reports failure instead of an unsaved success', async () => {
  const browser = sharedBrowser(legacy());
  const a = await page(browser);
  browser.localStorage.setItem = () => { throw new Error('Quota exceeded'); };
  const result = await a.run('scheduleSession(new Date(Date.now() + 3600000), 25, ["legacy-list"], false)');
  assert.equal(result, false);
  assert.equal(browser.state().sessions.scheduled.length, 0);
  assert.equal(a.run('S.scheduled.length'), 0);
  assert.match(a.alerts[0], /Quota exceeded/);
});

for (const editor of [
  { name: 'blocklist', open: 'openBlocklistEditor(null)', button: '#be-save', fields: { '#be-name': 'New list' }, count: (state) => state.blocklists.length - 1 },
  { name: 'rule', open: 'openRuleEditor(null)', button: '#re-save', fields: { '#re-name': 'New rule', '#re-from': '09:00', '#re-to': '10:00' }, count: (state) => state.sessions.rules.length },
  { name: 'queued session', open: 'openStartSheet(new Date(Date.now() + 3600000))', button: '#ss-go', fields: { '#ss-hours': '0', '#ss-mins': '25', '#ss-start': '2099-01-01T09:00' }, count: (state) => state.sessions.scheduled.length },
]) {
  test(`${editor.name} save ignores a second click while awaiting storage`, async () => {
    const browser = sharedBrowser(legacy());
    const a = await page(browser);
    a.run(editor.open);
    for (const [selector, value] of Object.entries(editor.fields)) a.document.querySelector(selector).value = value;
    const button = a.document.querySelector(editor.button);
    const first = button.dispatch('click');
    assert.equal(button.disabled, true);
    const second = button.dispatch('click');
    await Promise.all([first, second]);
    assert.equal(editor.count(browser.state()), 1);
  });

  test(`${editor.name} save can be retried after a storage failure`, async () => {
    const browser = sharedBrowser(legacy());
    const a = await page(browser);
    a.run(editor.open);
    for (const [selector, value] of Object.entries(editor.fields)) a.document.querySelector(selector).value = value;
    const button = a.document.querySelector(editor.button);
    const save = browser.localStorage.setItem;
    browser.localStorage.setItem = () => { throw new Error('Quota exceeded'); };
    await button.dispatch('click');
    assert.equal(button.disabled, false);
    assert.equal(editor.count(browser.state()), 0);
    browser.localStorage.setItem = save;
    await button.dispatch('click');
    assert.equal(editor.count(browser.state()), 1);
  });
}

test('coach drafts survive navigation and full shell rerenders', async () => {
  const a = await page(sharedBrowser(legacy()));
  a.run('switchTab("coach")');
  const input = a.document.querySelector('#coach-draft');
  input.value = 'My unsent question'; input.dispatch('input');
  a.run('switchTab("focus"); switchTab("coach"); render()');
  assert.equal(a.document.querySelector('#coach-draft').value, 'My unsent question');
});

test('a failed coach request restores text after the original input has been removed', async () => {
  let rejectRequest;
  const a = await page(sharedBrowser(legacy()), () => new Promise((_, reject) => { rejectRequest = reject; }));
  a.run('switchTab("coach")');
  const oldInput = a.document.querySelector('#coach-draft');
  const sent = a.run('submitCoach("Question still needs an answer")');
  a.run('switchTab("focus"); switchTab("coach")');
  const newInput = a.document.querySelector('#coach-draft');
  assert.notEqual(oldInput, newInput);
  rejectRequest(new Error('Offline'));
  await sent;
  assert.equal(newInput.value, 'Question still needs an answer');
  assert.equal(a.run('coachMessages.length'), 0);
});

test('a failed coach request keeps both the undelivered question and a newer draft', async () => {
  let rejectRequest;
  const a = await page(sharedBrowser(legacy()), () => new Promise((_, reject) => { rejectRequest = reject; }));
  a.run('switchTab("coach")');
  const sent = a.run('submitCoach("First question")');
  const input = a.document.querySelector('#coach-draft');
  input.value = 'Next thought'; input.dispatch('input');
  rejectRequest(new Error('Offline'));
  await sent;
  assert.match(a.run('coachDraft'), /First question/);
  assert.match(a.run('coachDraft'), /Next thought/);
});

test('storage mutex rejects unavailable IndexedDB without running an unsafe write', async () => {
  const run = createStorageLock('unavailable', null);
  let changed = false;
  await assert.rejects(run(() => { changed = true; }), /Enable IndexedDB/);
  assert.equal(changed, false);
});
