// All tabs share one atomic localStorage document. The injected lock serializes
// read/modify/write operations; IndexedDB supplies that lock even on LAN HTTP.
export function createDocumentStore({ storage, key, withLock, loadLegacy }) {
  function read() {
    const raw = storage.getItem(key);
    if (raw === null) return loadLegacy();
    const value = JSON.parse(raw);
    if (!value || !Array.isArray(value.entries) || !Array.isArray(value.tombstones) ||
        !value.goals || typeof value.goals !== "object") {
      throw new Error("Saved tracking data could not be read");
    }
    return value;
  }
  return {
    read,
    update(change) {
      return withLock(() => {
        const next = change(read());
        storage.setItem(key, JSON.stringify(next));
        return next;
      });
    },
  };
}
