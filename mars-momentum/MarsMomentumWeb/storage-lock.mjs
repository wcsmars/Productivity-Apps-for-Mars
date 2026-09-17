/* A readwrite IndexedDB transaction serializes localStorage read/modify/write
   across tabs, including on HTTP origins where Web Locks are unavailable. */
export function createStorageLock(databaseName, indexedDBFactory = globalThis.indexedDB) {
  let database;
  function openDatabase() {
    if (!database) {
      database = new Promise((resolve, reject) => {
        if (!indexedDBFactory) {
          reject(new Error("This browser cannot safely save shared app data. Enable IndexedDB storage and reload."));
          return;
        }
        const request = indexedDBFactory.open(databaseName, 1);
        request.onupgradeneeded = () => request.result.createObjectStore("mutex");
        request.onerror = () => reject(request.error);
        request.onsuccess = () => {
          const db = request.result;
          db.onversionchange = () => { db.close(); database = null; };
          resolve(db);
        };
      }).catch((error) => { database = null; throw error; });
    }
    return database;
  }
  return async function withStorageLock(action) {
    const db = await openDatabase();
    return new Promise((resolve, reject) => {
      const transaction = db.transaction("mutex", "readwrite");
      let result;
      let failure;
      transaction.oncomplete = () => resolve(result);
      transaction.onabort = () => reject(failure || transaction.error || new Error("Saving app data was interrupted."));
      transaction.onerror = () => {};
      const request = transaction.objectStore("mutex").get("lock");
      request.onsuccess = () => {
        try {
          // Never await inside this callback: the transaction must remain active
          // until the complete localStorage mutation has finished.
          result = action();
          if (result && typeof result.then === "function") {
            throw new Error("Storage mutations must be synchronous.");
          }
        } catch (error) {
          failure = error;
          transaction.abort();
        }
      };
    });
  };
}

