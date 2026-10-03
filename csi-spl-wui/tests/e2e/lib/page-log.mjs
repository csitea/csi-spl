// What a page saw, and the one retry for runner network churn.
//
// A blank page used to explain nothing: Chrome aborted a chunk, the next
// waitForSelector waited 60 s, and the log said only "Waiting for selector
// ... failed" (wf10 37090758900 / 37087180918: avatars-visible, issues-mobile).
//
//   watchPage(page, label)  - records the page's failed requests, console
//                             errors and page errors from now on;
//   printPageLog(why)       - prints what was recorded and not printed yet
//                             (or that there was nothing: a clean page).
//                             A test calls it when a check fails; it runs by
//                             itself when the process exits non-zero (an
//                             uncaught timeout included);
//   retryOnNetworkChanged(name, attempt, { failed, onRetry })
//                           - runs attempt(); when it threw or failed(value)
//                             AND a watched page saw net::ERR_NETWORK_CHANGED
//                             meanwhile, logs RETRY and runs it ONCE more.
//                             Any other failure stands.
//
// Why net::ERR_NETWORK_CHANGED: docker veth churn on the shared self-hosted
// runners makes Chrome abort in-flight loads with it; a page chunk then never
// arrives and the page stays blank (c-081, i18n-split, /fi/lobby). It is no
// defect of the WUI, so that one error buys one more try and nothing else does.
//
// Mutant for the retry: lib/mutant-network-changed.mjs.
export const NETWORK_CHANGED = 'net::ERR_NETWORK_CHANGED'

const entries = []
let seq = 0
let pages = 0
const MAX_PRINT = 40

const short = (url) => String(url).replace(/^https?:\/\/[^/]+/, '').slice(0, 160)

export function watchPage(page, label = `page${++pages}`) {
  const add = (kind, text) => entries.push({ seq: ++seq, label, kind, text: String(text).slice(0, 300), printed: false })
  page.on('requestfailed', (r) => add('requestfailed', `${r.failure()?.errorText ?? '?'} ${r.method()} ${short(r.url())}`))
  page.on('console', (m) => { if (m.type() === 'error') add('console.error', `${m.text()}${m.location()?.url ? ' @' + short(m.location().url) : ''}`) })
  page.on('pageerror', (e) => add('pageerror', e?.message ?? e))
  return page
}

export function printPageLog(why) {
  const fresh = entries.filter((e) => !e.printed)
  if (!fresh.length) {
    console.log(`  page log (${why}): no failed request, console error or page error since the last print`)
    return
  }
  console.log(`  page log (${why}): ${fresh.length} entr${fresh.length === 1 ? 'y' : 'ies'}`)
  for (const e of fresh.slice(-MAX_PRINT)) console.log(`    [${e.label}] ${e.kind} ${e.text}`)
  if (fresh.length > MAX_PRINT) console.log(`    ... ${fresh.length - MAX_PRINT} earlier entries not shown`)
  for (const e of fresh) e.printed = true
}

process.on('exit', (code) => { if (code) printPageLog(`exit ${code}`) })

const sawNetworkChanged = (since) => entries.some((e) => e.seq > since && e.kind === 'requestfailed' && e.text.startsWith(NETWORK_CHANGED))

/**
 * attempt(n) once; once more only when it failed on a page that saw
 * net::ERR_NETWORK_CHANGED. failed(value) -> falsy when the attempt passed,
 * else true or what failed (printed). onRetry() drops what the first attempt
 * left behind (page errors it counted, ...).
 */
export async function retryOnNetworkChanged(name, attempt, { failed = () => false, onRetry = () => {} } = {}) {
  const mark = seq
  let value
  let why
  try {
    value = await attempt(1)
    why = failed(value)
  } catch (e) {
    why = String(e?.message ?? e).slice(0, 200)
    if (!sawNetworkChanged(mark)) throw e
  }
  if (!why || !sawNetworkChanged(mark)) return value
  console.log(`  RETRY ${name}: the page saw ${NETWORK_CHANGED} (runner network churn); first attempt failed ${JSON.stringify(why)}`)
  printPageLog(`${name}, attempt 1`)
  await onRetry()
  return attempt(2)
}
