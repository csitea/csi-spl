// Layering across components reads the named scale in assets/css/variables.css
// (--z-sticky / --z-popover / --z-banner / --z-snackbar / --z-overlay /
// --z-drawer / --z-modal), never a raw number (CLE-77915, refactor item 13).
// A raw z-index below 40 is a component's own stacking (a sticky header over
// its rows, a badge over its card) and stays a literal; 40 and up is a layer
// another component has to know about, so it is a token - except the pairs
// below, each with its reason.
//
// Run: node tests/unit/css-z-scale.test.mjs
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const GLOBAL_FROM = 40

const ALLOWED = new Set([
  'src/components/MentionList.vue 60', // above the composer it opens from, under the snackbar
  'src/components/TopBar.vue 60', // the send-error line over the top bar's own popovers
  'src/components/MessageComposer.vue 60', // CLE-77917's open file: tokenise after it lands
  'src/components/MessageComposer.vue 70',
])

function walk(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else if (/\.(vue|css)$/.test(e.name)) out.push(p)
  }
  return out
}

let failed = 0
let raw = 0
let tokens = 0
for (const f of walk(join(WUI, 'src'))) {
  const rel = relative(WUI, f)
  if (rel.endsWith('assets/css/variables.css')) continue
  const css = readFileSync(f, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
  tokens += (css.match(/z-index:\s*var\(--z-/g) || []).length
  for (const [, n] of css.matchAll(/z-index:\s*(\d+)/g)) {
    raw++
    if (Number(n) >= GLOBAL_FROM && !ALLOWED.has(`${rel} ${n}`)) {
      failed++
      console.log(`  FAIL ${rel}: z-index ${n} is a cross-component layer - use a --z-* token (or add a reasoned pair here)`)
    }
  }
}
if (raw + tokens < 30) { failed++; console.log(`  FAIL saw only ${raw + tokens} z-index rules: the scan is blind`) }
console.log(failed ? `\ncss-z-scale: ${failed} FAILED` : `css-z-scale: ${tokens} token layers, ${raw} local literals, none global outside the scale`)
process.exit(failed ? 1 : 0)
