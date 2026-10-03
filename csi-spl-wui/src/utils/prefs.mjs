/** localStorage helpers. Every write is try/catch (private mode). */

function backend(store) {
  if (store && typeof store.getItem === 'function') return store
  try {
    if (typeof globalThis !== 'undefined' && globalThis.localStorage) return globalThis.localStorage
  } catch {
    /* denied */
  }
  return null
}

export function storageGet(key, fallback = null, store) {
  try {
    const s = backend(store)
    if (!s) return fallback
    const v = s.getItem(key)
    return v == null ? fallback : v
  } catch {
    return fallback
  }
}

export function storageSet(key, value, store) {
  try {
    const s = backend(store)
    if (!s) return false
    s.setItem(key, String(value))
    return true
  } catch {
    return false
  }
}

export function storageGetJson(key, fallback, store) {
  const raw = storageGet(key, null, store)
  if (raw == null) return fallback
  try {
    return JSON.parse(raw)
  } catch {
    return fallback
  }
}

export function storageSetJson(key, value, store) {
  try {
    return storageSet(key, JSON.stringify(value), store)
  } catch {
    return false
  }
}

/** In-memory Storage-shaped object for unit tests. */
export function memoryStore(init = {}) {
  const m = { ...init }
  return {
    getItem(key) {
      return Object.hasOwn(m, key) ? m[key] : null
    },
    setItem(key, value) {
      m[key] = String(value)
    },
    removeItem(key) {
      delete m[key]
    },
    _data: m,
  }
}
