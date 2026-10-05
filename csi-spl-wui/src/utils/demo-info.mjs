/**
 * specs/077 T020: GET /v1/demo, the demo workspace and the limits the hub
 * enforces today. Public and cookie-free; 200 only while the demo flag is
 * on, 404 while it is off. Anything else (no hub, the SPA fallback's HTML, a
 * body without a workspace) reads as "off", so the sign-in page stays as it
 * was.
 */
export const DEMO_PATH = '/v1/demo'

/**
 * The sign-ins the open demo admission accepts (T007: hub env
 * SPOOL_HUB_DEMO_PROVIDERS, default google,facebook; a password or operator
 * identity never). GET /v1/demo does not name them yet.
 */
export const DEMO_PROVIDERS = ['google', 'facebook']

const LABEL = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/

/** { workspace, maxLive } from a GET /v1/demo body; null when it is not one. */
export function parseDemo(body) {
  const workspace = String((body && body.workspace) || '')
  if (!LABEL.test(workspace)) return null
  const n = body.max_live
  return { workspace, maxLive: Number.isInteger(n) && n > 0 ? n : 0 }
}

/** The registry's providers that may enter the demo, in the registry's order. */
export function demoProviders(list) {
  return (Array.isArray(list) ? list : []).filter((p) => DEMO_PROVIDERS.includes(p))
}

/** GET <base>/v1/demo: parseDemo of a 200, else null. Never throws. */
export async function loadDemo(base = '', fetchFn = globalThis.fetch) {
  try {
    const root = String(base || '').replace(/\/+$/, '')
    const res = await fetchFn(`${root}${DEMO_PATH}`, { credentials: 'omit', headers: { accept: 'application/json' } })
    if (!res || res.status !== 200) return null
    return parseDemo(await res.json())
  } catch {
    return null
  }
}
