// One phone breakpoint (CLE-77915, refactor item 8). The phone layout starts
// at MOBILE_STACK_MAX_PX (utils/mobile-stack.mjs) and nowhere else decides it:
//
//   • JS reads it: no `(max-width: 820px)` string and no second 820 constant
//     outside mobile-stack.mjs (UserMenu, TenantDropBox, slash-focus and
//     usePaneWidths each carried their own copy on 2026-10-02)
//   • CSS cannot import a JS constant (no custom-media plugin in the build), so
//     every @media width in src is checked here: the phone rule is exactly
//     max-width MOBILE_STACK_MAX_PX / min-width MOBILE_STACK_MAX_PX + 1, and any
//     other width must be one of OTHER_WIDTHS - a new breakpoint is named here,
//     on purpose, instead of appearing as a stray number
//
// Run: node tests/unit/breakpoint-single-source.test.mjs
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { MOBILE_STACK_MAX_PX } from '../../src/utils/mobile-stack.mjs'
import { MOBILE_MAX } from '../../src/utils/slash-focus.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const SRC = join(WUI, 'src')

// The other widths in use on 2026-10-02 (max-width unless marked): narrow
// dialogs and sheets (480, 600 / min 600, 601), the settings two-column
// split (640), the issue sheet (min 760) and the wide sidebar rule (1100).
const OTHER_WIDTHS = new Set(['max-480', 'max-600', 'min-600', 'min-601', 'max-640', 'min-760', 'max-1100'])

let failed = 0
const fail = (m) => { failed++; console.log(`  FAIL ${m}`) }

function walk(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) { if (e.name !== 'node') walk(p, out) } else if (/\.(vue|css|ts|mjs|js)$/.test(e.name) && !e.name.endsWith('.d.ts')) out.push(p)
  }
  return out
}
const noComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/<!--[\s\S]*?-->/g, '').replace(/(^|[^:'"`])\/\/.*$/gm, '$1')

if (MOBILE_MAX !== MOBILE_STACK_MAX_PX) fail(`slash-focus MOBILE_MAX ${MOBILE_MAX} != MOBILE_STACK_MAX_PX ${MOBILE_STACK_MAX_PX}`)

const P = MOBILE_STACK_MAX_PX
let media = 0
for (const file of walk(SRC)) {
  const rel = relative(WUI, file)
  const code = noComments(readFileSync(file, 'utf8'))
  /* the script half only: a CSS width of 820 px (a content column) is not the breakpoint */
  const js = rel.endsWith('.css') ? '' : code.replace(/<style[\s\S]*?<\/style>/g, '')
  if (!rel.endsWith('utils/mobile-stack.mjs')) {
    if (new RegExp(`max-width:\\s*${P}px`).test(js)) fail(`${rel}: writes the phone media query by hand - use MOBILE_STACK_QUERY`)
    if (new RegExp(`=\\s*${P}\\b`).test(js)) fail(`${rel}: a second ${P} constant - import MOBILE_STACK_MAX_PX`)
  }
  for (const m of code.matchAll(/@media[^{]*\{/g)) {
    for (const [, side, px] of m[0].matchAll(/(max|min)-width:\s*(\d+)px/g)) {
      media++
      const n = Number(px)
      const phone = (side === 'max' && n === P) || (side === 'min' && n === P + 1)
      if (!phone && !OTHER_WIDTHS.has(`${side}-${n}`)) fail(`${rel}: @media ${side}-width ${n}px is neither the phone breakpoint (${P}) nor a named width`)
    }
  }
}
if (media < 50) fail(`saw only ${media} @media widths: the walk is broken, not the code`)

// Control: the matchers must see a stray value.
const probe = '@media (max-width: 819px) {'
if ([...probe.matchAll(/(max|min)-width:\s*(\d+)px/g)].length !== 1) fail('control: the width matcher missed a stray value')

console.log(failed ? `\nbreakpoint-single-source: ${failed} FAILED` : `breakpoint-single-source: ${media} @media widths, phone = ${P} px from one constant`)
process.exit(failed ? 1 : 0)
