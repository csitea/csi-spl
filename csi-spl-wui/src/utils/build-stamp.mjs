/**
 * CLE-3433 — what the version footer should say.
 *
 * The footer read a bare `v0.1.0` from `csi-spl-wui/.version`, which is a real
 * marker nobody has bumped, so it answered a question nobody asks and NOT the
 * one they do: "am I looking at the build that carries the fix?". The deploy
 * workflow already writes `/build.json` next to the page (30_wui-build-deploy,
 * "Stamp build.json") with the commit, the build time and the run id, and it
 * is same-origin, so the shell can simply read it.
 *
 * The semver stays the leading token: this ADDS the build, it does not invent
 * a version. With no build.json — lde, `nuxt generate` served straight off
 * disk — the footer is exactly what it was.
 */

/** A short commit for humans; anything that is not a hex sha is left alone. */
export function shortCommit(commit) {
  const s = String(commit || '').trim()
  return /^[0-9a-f]{7,40}$/i.test(s) ? s.slice(0, 7) : ''
}

/**
 * @param {string} version  e.g. 'v0.1.0'
 * @param {{ commit?: string, built_at?: string, run?: string } | null} [build]
 */
export function buildStampText(version, build) {
  const v = String(version || '').trim()
  const c = shortCommit(build && build.commit)
  return c ? `${v} · ${c}` : v
}

/**
 * The hover/screen-reader detail. Empty when there is no build to describe,
 * so the element carries no empty title attribute.
 * @param {{ commit?: string, built_at?: string, run?: string } | null} [build]
 */
export function buildStampTitle(build) {
  if (!build) return ''
  const bits = []
  if (build.commit) bits.push(String(build.commit))
  if (build.built_at) bits.push(String(build.built_at))
  if (build.run) bits.push(`run ${build.run}`)
  return bits.join(' · ')
}

/**
 * Read the deployed stamp. Never throws and never rejects: a missing or
 * malformed build.json must leave the footer alone, not break the shell.
 * @param {(input: string, init?: object) => Promise<Response>} [fetchImpl]
 */
export async function readBuildStamp(fetchImpl) {
  const f = fetchImpl || (typeof fetch === 'function' ? fetch : null)
  if (!f) return null
  try {
    const r = await f('/build.json', { cache: 'no-cache' })
    if (!r || !r.ok) return null
    const j = await r.json()
    return j && typeof j === 'object' && shortCommit(j.commit) ? j : null
  } catch {
    return null
  }
}
