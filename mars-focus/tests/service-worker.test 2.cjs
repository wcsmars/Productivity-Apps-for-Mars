const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

const source = fs.readFileSync(path.join(__dirname, "../MarsFocusWeb/sw.js"), "utf8");

function worker() {
  const events = new Map();
  const deleted = [];
  const opened = [];
  const network = [];
  const context = {
    URL, Request,
    self: {
      location: { origin: "https://example.test" },
      clients: { claim: async () => {} },
      addEventListener: (name, listener) => events.set(name, listener),
    },
    caches: {
      keys: async () => ["track-on-me-v7", "track-on-me-v8", "mars-tracking-v8", "other-app"],
      delete: async (name) => { deleted.push(name); },
      open: async (name) => { opened.push(name); return { match: async () => "own cached shell" }; },
    },
    fetch: async (request) => { network.push(request.url); return "network"; },
  };
  vm.runInNewContext(source, context);
  return { events, deleted, opened, network };
}

test("activation deletes only older Mars Focus caches", async () => {
  const w = worker();
  let completion;
  w.events.get("activate")({ waitUntil: (task) => { completion = task; } });
  await completion;
  assert.deepEqual(w.deleted, ["track-on-me-v7"]);
});

test("fetch reads only this version's cache", async () => {
  const w = worker();
  let response;
  w.events.get("fetch")({ request: new Request("https://example.test/app.js"), respondWith: (task) => { response = task; } });
  assert.equal(await response, "own cached shell");
  assert.deepEqual(w.opened, ["track-on-me-v8"]);
});

test("API calls and lookalike foreign origins are not intercepted", () => {
  const w = worker();
  for (const request of [
    new Request("https://generativelanguage.googleapis.com/test"),
    new Request("https://example.test.attacker.test/test"),
    new Request("https://example.test/api", { method: "POST" }),
  ]) {
    w.events.get("fetch")({ request, respondWith: () => assert.fail("Unexpected interception") });
  }
});
