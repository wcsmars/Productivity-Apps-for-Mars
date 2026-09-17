const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function newId(random = globalThis.crypto) {
  if (random.randomUUID) return random.randomUUID();
  // getRandomValues also works on HTTP LAN origins where randomUUID is absent.
  const bytes = random.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = [...bytes].map(b => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function mergeDocs(remote, local, preferLocalGoals = false) {
  if (!remote || !Array.isArray(remote.entries) || !Array.isArray(remote.tombstones) ||
      !remote.goals || typeof remote.goals !== "object") {
    throw new Error("Invalid sync document from server");
  }
  const mappings = remote.idMappings || {};
  const idFor = value => {
    const id = typeof value === "string" ? value.toLowerCase() : "";
    return Object.hasOwn(mappings, id) && UUID_RE.test(mappings[id]) ? mappings[id].toLowerCase() : id;
  };
  const tombstones = new Map();
  for (const t of [...remote.tombstones, ...local.tombstones]) {
    const id = idFor(t.id);
    if (id && !tombstones.has(id)) tombstones.set(id, { ...t, id });
  }
  const entries = new Map();
  for (const e of [...remote.entries, ...local.entries]) {
    const id = idFor(e.id);
    if (id && !tombstones.has(id) && !entries.has(id)) entries.set(id, { ...e, id });
  }
  const remoteTime = Date.parse(remote.goalsUpdatedAt || "") || 0;
  const localTime = Date.parse(local.goalsUpdatedAt || "") || 0;
  const goalsSource = preferLocalGoals || localTime > remoteTime ? local : remote;
  return {
    entries: [...entries.values()], tombstones: [...tombstones.values()],
    goals: goalsSource.goals, goalsUpdatedAt: goalsSource.goalsUpdatedAt || null,
  };
}

// Keep each session's request separate from later logins, and drain local edits
// made during a request before reporting the device as synchronized.
export function createSyncController({ readDoc, applyDoc, request, onState = () => {}, onSynced = () => {} }) {
  let account = null;
  let generation = 0;
  let revision = 0;
  let active = null;
  return {
    setAccount(value) {
      account = value ? { ...value } : null;
      generation += 1;
      active = null;
      onState("idle");
    },
    mutated() { revision += 1; },
    sync() {
      if (!account) return Promise.resolve();
      if (active) return active;
      const session = account;
      const requestGeneration = generation;
      onState("syncing");
      active = (async () => {
        try {
          while (requestGeneration === generation) {
            const sentRevision = revision;
            const sent = JSON.parse(JSON.stringify(readDoc()));
            const response = await request(sent, session);
            if (requestGeneration !== generation) return;
            const current = readDoc();
            const goalsChanged = current.goalsUpdatedAt !== sent.goalsUpdatedAt ||
              JSON.stringify(current.goals) !== JSON.stringify(sent.goals);
            await applyDoc(mergeDocs(response, current, goalsChanged), {
              response, sent, session, isCurrent: () => requestGeneration === generation,
            });
            if (requestGeneration !== generation) return;
            if (revision === sentRevision) {
              onSynced();
              onState("idle");
              return;
            }
          }
        } catch (error) {
          if (requestGeneration === generation) onState(String(error.message || error));
        } finally {
          if (requestGeneration === generation) active = null;
        }
      })();
      return active;
    },
  };
}
