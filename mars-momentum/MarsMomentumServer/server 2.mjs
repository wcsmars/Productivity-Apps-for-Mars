/* Mars Momentum sync server — zero-dependency Node (>= 18).
 *
 *   node server.mjs                # http://localhost:8473
 *   PORT=9000 node server.mjs      # custom port
 *   MARS_DATA_DIR=/srv/mars node server.mjs
 *
 * Serves the MarsMomentumWeb PWA at / and a small account+sync API at /api/*.
 * Accounts are username+password (scrypt-hashed); sessions are random bearer
 * tokens. Each user's data is one JSON doc: entries (union-merged by id),
 * tombstones for deletions, and goals (last-writer-wins by goalsUpdatedAt).
 *
 * Run it behind HTTPS (reverse proxy, Tailscale, etc.) for anything beyond
 * localhost — bearer tokens over plain LAN http are readable by the network.
 */

import { createServer } from "node:http";
import { createHash, randomBytes, scryptSync, timingSafeEqual } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync, existsSync, renameSync } from "node:fs";
import { join, dirname, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const PORT = Number(process.env.PORT) || 8473;
const ROOT = dirname(fileURLToPath(import.meta.url));

// A request the client got wrong carries its own status and message. Anything
// else is a server fault: it is logged, and the client sees a generic 500.
class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function createRequestHandler({ dataDir = process.env.MARS_DATA_DIR || join(ROOT, "data") } = {}) {
  const DATA_DIR = dataDir;
  const USERS_DIR = join(DATA_DIR, "users");
  const STATIC_DIR = resolve(ROOT, "..", "MarsMomentumWeb");

  const MAX_BODY = 5 * 1024 * 1024;
  const MAX_ENTRIES = 100_000;
  const MAX_TOKENS = 10;
  const MAX_LOGIN_SLOTS = 10_000;
  const USERNAME_RE = /^[a-z0-9_-]{3,32}$/;
  const CATEGORIES = new Set(["study", "gym", "cardio", "weight"]);
  const KINDS = new Set(["number", "duration"]);
  const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  // Older browser releases used non-UUID IDs. Derive the same UUID on every
  // request so old devices, server records and deletion tombstones still agree.
  function canonicalId(value, mappings) {
    if (typeof value !== "string" || !value.length || value.length > 64) return null;
    const id = value.toLowerCase();
    if (UUID_RE.test(id)) return id;
    const bytes = createHash("sha256").update("mars-tracking-legacy-id:" + id).digest().subarray(0, 16);
    bytes[6] = (bytes[6] & 0x0f) | 0x80;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = bytes.toString("hex");
    const uuid = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    mappings[id] = uuid;
    return uuid;
  }

  mkdirSync(USERS_DIR, { recursive: true });

  /* ---------- user storage ---------- */

  const userPath = (username) => join(USERS_DIR, `${username}.json`);

  function loadUser(username) {
    if (!USERNAME_RE.test(username)) return null;
    try { return JSON.parse(readFileSync(userPath(username), "utf8")); }
    catch { return null; }
  }

  function saveUser(user) {
    const path = userPath(user.username);
    const tmp = `${path}.tmp`;
    writeFileSync(tmp, JSON.stringify(user));
    renameSync(tmp, path); // atomic on the same filesystem
  }

  function hashPassword(password, saltHex) {
    const salt = saltHex ? Buffer.from(saltHex, "hex") : randomBytes(16);
    const hash = scryptSync(password, salt, 64);
    return { salt: salt.toString("hex"), hash: hash.toString("hex") };
  }

  function verifyPassword(user, password) {
    const { hash } = hashPassword(password, user.salt);
    const a = Buffer.from(hash, "hex");
    const b = Buffer.from(user.hash, "hex");
    return a.length === b.length && timingSafeEqual(a, b);
  }

  /* ---------- login rate limiting ---------- */

  const attempts = new Map(); // username -> { count, resetAt }

  function rateLimited(username) {
    const now = Date.now();
    for (const [name, slot] of attempts) {
      if (now >= slot.resetAt) attempts.delete(name);
    }
    const slot = attempts.get(username);
    if (!slot) {
      if (attempts.size >= MAX_LOGIN_SLOTS) return true;
      attempts.set(username, { count: 1, resetAt: now + 15 * 60 * 1000 });
      return false;
    }
    slot.count += 1;
    return slot.count > 10;
  }

  /* ---------- doc validation & merge ---------- */

  const isIsoDate = (s) => typeof s === "string" && !Number.isNaN(Date.parse(s));

  function sanitizeDoc(raw, mappings = Object.create(null)) {
    const doc = raw && typeof raw === "object" ? raw : {};
    if ((Array.isArray(doc.entries) && doc.entries.length > MAX_ENTRIES) ||
        (Array.isArray(doc.tombstones) && doc.tombstones.length > MAX_ENTRIES)) {
      throw new HttpError(400, "document record limit exceeded");
    }
    const entries = [];
    if (Array.isArray(doc.entries)) {
      for (const e of doc.entries) {
        if (e && typeof e === "object" &&
            canonicalId(e.id, mappings) &&
            CATEGORIES.has(e.category) && KINDS.has(e.kind) &&
            typeof e.amount === "number" && isFinite(e.amount) && e.amount >= 0 &&
            isIsoDate(e.date)) {
          // Lowercase ids: Swift emits uppercase UUIDs, the web lowercase — the
          // union merge must treat them as the same entry.
          entries.push({ id: canonicalId(e.id, mappings), date: new Date(e.date).toISOString(), category: e.category, kind: e.kind, amount: e.amount });
        }
      }
    }
    const tombstones = [];
    if (Array.isArray(doc.tombstones)) {
      for (const t of doc.tombstones) {
        if (t && typeof t === "object" && canonicalId(t.id, mappings)) {
          tombstones.push({ id: canonicalId(t.id, mappings), deletedAt: isIsoDate(t.deletedAt) ? new Date(t.deletedAt).toISOString() : null });
        }
      }
    }
    const goals = {};
    if (doc.goals && typeof doc.goals === "object") {
      for (const c of CATEGORIES) {
        const g = doc.goals[c];
        if (g && typeof g === "object" && KINDS.has(g.kind) &&
            typeof g.amount === "number" && isFinite(g.amount) && g.amount > 0) {
          goals[c] = { kind: g.kind, amount: g.amount };
        }
      }
    }
    return {
      entries,
      tombstones,
      goals,
      goalsUpdatedAt: isIsoDate(doc.goalsUpdatedAt) ? new Date(doc.goalsUpdatedAt).toISOString() : null,
    };
  }

  function mergeDocs(stored, incoming) {
    const tombstones = new Map();
    for (const t of [...stored.tombstones, ...incoming.tombstones]) {
      if (!tombstones.has(t.id)) tombstones.set(t.id, t.deletedAt);
    }
    const entries = new Map();
    for (const e of [...stored.entries, ...incoming.entries]) {
      if (!tombstones.has(e.id) && !entries.has(e.id)) entries.set(e.id, e);
    }
    const storedTime = Date.parse(stored.goalsUpdatedAt ?? "") || 0;
    const incomingTime = Date.parse(incoming.goalsUpdatedAt ?? "") || 0;
    const goalsSource = incomingTime >= storedTime ? incoming : stored;
    return {
      entries: [...entries.values()],
      tombstones: [...tombstones.entries()].map(([id, deletedAt]) => ({ id, deletedAt })),
      goals: goalsSource.goals,
      goalsUpdatedAt: goalsSource.goalsUpdatedAt,
    };
  }

  const emptyDoc = () => ({ entries: [], tombstones: [], goals: {}, goalsUpdatedAt: null });

  /* ---------- http plumbing ---------- */

  function send(res, status, body, headers = {}) {
    const data = typeof body === "string" ? body : JSON.stringify(body);
    res.writeHead(status, {
      "Content-Type": typeof body === "string" ? "text/plain" : "application/json",
      "Access-Control-Allow-Origin": "*",
      ...headers,
    });
    res.end(data);
  }

  function readBody(req) {
    return new Promise((resolvePromise, reject) => {
      let size = 0;
      const chunks = [];
      req.on("data", (chunk) => {
        size += chunk.length;
        if (size > MAX_BODY) { reject(new HttpError(413, "body too large")); req.destroy(); return; }
        chunks.push(chunk);
      });
      req.on("end", () => {
        let body;
        try { body = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"); }
        catch { return reject(new HttpError(400, "invalid JSON")); }
        resolvePromise(body ?? {}); // a literal null body reads as an empty one
      });
      req.on("error", () => reject(new HttpError(400, "request aborted")));
    });
  }

  function authenticate(req) {
    const header = req.headers.authorization || "";
    const match = header.match(/^Bearer ([a-f0-9]{64})$/);
    if (!match) return null;
    const username = String(req.headers["x-mars-user"] || "").toLowerCase();
    const user = loadUser(username);
    if (!user || !Array.isArray(user.tokens) || !user.tokens.includes(match[1])) return null;
    return { user, token: match[1] };
  }

  function issueToken(user) {
    const token = randomBytes(32).toString("hex");
    user.tokens = [...(user.tokens || []), token].slice(-MAX_TOKENS);
    saveUser(user);
    return token;
  }

  /* ---------- static files ---------- */

  const MIME = {
    ".html": "text/html", ".css": "text/css", ".js": "text/javascript",
    ".mjs": "text/javascript", ".json": "application/json",
    ".webmanifest": "application/manifest+json", ".png": "image/png", ".svg": "image/svg+xml",
  };

  function serveStatic(res, urlPath) {
    const clean = urlPath === "/" ? "/index.html" : urlPath;
    const target = resolve(STATIC_DIR, `.${clean}`);
    if (!target.startsWith(STATIC_DIR + sep) || !existsSync(target)) {
      return send(res, 404, "not found");
    }
    const ext = clean.slice(clean.lastIndexOf("."));
    res.writeHead(200, {
      "Content-Type": MIME[ext] || "application/octet-stream",
      "Access-Control-Allow-Origin": "*",
    });
    res.end(readFileSync(target));
  }

  /* ---------- routes ---------- */

  return async (req, res) => {
    try {
      // The Host header is not needed to resolve a request path.
      let url;
      try { url = new URL(req.url, "http://localhost"); }
      catch { throw new HttpError(400, "invalid request URL"); }
      const path = url.pathname;

      if (req.method === "OPTIONS") {
        res.writeHead(204, {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Mars-User",
          "Access-Control-Max-Age": "86400",
        });
        return res.end();
      }

      if (path === "/api/health") return send(res, 200, { ok: true });

      if (path === "/api/register" && req.method === "POST") {
        const { username = "", password = "" } = await readBody(req);
        const name = typeof username === "string" ? username.toLowerCase().trim() : "";
        if (!USERNAME_RE.test(name)) return send(res, 400, { error: "username must be 3-32 chars: a-z 0-9 _ -" });
        if (typeof password !== "string" || password.length < 8) return send(res, 400, { error: "password must be at least 8 characters" });
        if (existsSync(userPath(name))) return send(res, 409, { error: "username already taken" });
        const { salt, hash } = hashPassword(password);
        const user = { username: name, salt, hash, tokens: [], doc: emptyDoc() };
        const token = issueToken(user);
        return send(res, 201, { token, username: name });
      }

      if (path === "/api/login" && req.method === "POST") {
        const { username = "", password = "" } = await readBody(req);
        const name = typeof username === "string" ? username.toLowerCase().trim() : "";
        if (!USERNAME_RE.test(name)) return send(res, 400, { error: "username must be 3-32 chars: a-z 0-9 _ -" });
        if (rateLimited(name)) return send(res, 429, { error: "too many attempts — try again later" });
        const user = loadUser(name);
        if (!user || typeof password !== "string" || !verifyPassword(user, password)) {
          return send(res, 401, { error: "wrong username or password" });
        }
        attempts.delete(name);
        const token = issueToken(user);
        return send(res, 200, { token, username: name });
      }

      if (path === "/api/logout" && req.method === "POST") {
        const auth = authenticate(req);
        if (!auth) return send(res, 401, { error: "unauthorized" });
        auth.user.tokens = auth.user.tokens.filter((t) => t !== auth.token);
        saveUser(auth.user);
        return send(res, 200, { ok: true });
      }

      if (path === "/api/data" && req.method === "GET") {
        const auth = authenticate(req);
        if (!auth) return send(res, 401, { error: "unauthorized" });
        const idMappings = Object.create(null);
        const migrated = mergeDocs(emptyDoc(), sanitizeDoc(auth.user.doc, idMappings));
        auth.user.doc = migrated;
        saveUser(auth.user);
        return send(res, 200, { ...migrated, idMappings });
      }

      if (path === "/api/sync" && req.method === "POST") {
        if (!authenticate(req)) return send(res, 401, { error: "unauthorized" });
        const raw = await readBody(req);
        // A body may arrive after another sync or logout. Reload and validate the
        // session again, then merge/save without an await in this critical section.
        const auth = authenticate(req);
        if (!auth) return send(res, 401, { error: "unauthorized" });
        const idMappings = Object.create(null);
        const incoming = sanitizeDoc(raw, idMappings);
        const merged = mergeDocs(sanitizeDoc(auth.user.doc, idMappings), incoming);
        if (merged.entries.length > MAX_ENTRIES || merged.tombstones.length > MAX_ENTRIES) {
          return send(res, 413, { error: "account record limit reached" });
        }
        auth.user.doc = merged;
        saveUser(auth.user);
        return send(res, 200, { ...merged, idMappings });
      }

      if (path.startsWith("/api/")) return send(res, 404, { error: "not found" });

      if (req.method === "GET") return serveStatic(res, path);
      return send(res, 405, "method not allowed");
    } catch (error) {
      if (error instanceof HttpError && !res.headersSent) {
        return send(res, error.status, { error: error.message });
      }
      console.error(error);
      if (res.headersSent) return res.destroy();
      return send(res, 500, { error: "internal server error" });
    }
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  createServer(createRequestHandler()).listen(PORT, () => {
    console.log(`Mars Momentum server on http://localhost:${PORT}`);
  });
}
