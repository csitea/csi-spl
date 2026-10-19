// SPL-2466 row 01 (md-tables panel plan v1.0, section 3.1): a table in a
// post paints alternate body rows with the translucent --color-row-alt veil,
// for a pipe table (rows under <tbody>) and an HTML table (rows straight under
// <table>), and the zebra band stays visible on an odd (clear) card and on an
// even (already veiled) one, in every palette of variables.css.
//
// Red control: on a MarkdownBlock.vue without the zebra rule every body row
// computes to rgba(0,0,0,0); this test then fails its first two checks.
//
// Run: node tests/unit/markdown-table-zebra.test.mjs
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const WUI = join(here, '../..')
let failed = 0
const ok = (name, cond, why = '') => {
  if (cond) console.log(`  OK   ${name}`)
  else { failed++; console.log(`  FAIL ${name} ${why}`) }
}

const vue = readFileSync(join(WUI, 'src/components/MarkdownBlock.vue'), 'utf8')
const style = vue.slice(vue.indexOf('<style'))
// each rule as [selector, body], comments dropped
const rules = [...style.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/([^{}]+)\{([^{}]*)\}/g)]
  .map((m) => [m[1].trim().replace(/\s+/g, ' '), m[2]])
const ruleFor = (re) => rules.find(([sel]) => re.test(sel))

const zebra = ruleFor(/tbody > tr:nth-child\(even\)/)
ok('a pipe table zebra bands its even tbody rows with --color-row-alt',
  Boolean(zebra) && /background:\s*var\(--color-row-alt\)/.test(zebra[1]), JSON.stringify(zebra))
ok('an HTML table without tbody zebra bands its even data rows too (a header row of th is not counted)',
  Boolean(zebra) && /table > tr:nth-child\(even of tr:has\(> td\)\)/.test(zebra[0]), JSON.stringify(zebra))
ok('the zebra band keeps the .md-block weight (:where), so hover and modifiers win',
  Boolean(zebra) && /:where\(/.test(zebra[0]), JSON.stringify(zebra && zebra[0]))
const hover = ruleFor(/tr:hover/)
ok('a hovered row gets a 4% fg tint',
  Boolean(hover) && /color-mix\(in srgb, var\(--color-fg\) 4%, transparent\)/.test(hover[1]), JSON.stringify(hover))
ok('hover is declared after the zebra band', Boolean(zebra && hover) && rules.indexOf(hover) > rules.indexOf(zebra))
const noZebra = ruleFor(/\.md-table--no-zebra/)
ok('.md-table--no-zebra clears the zebra band', Boolean(noZebra) && /background:\s*none/.test(noZebra[1]))
ok('.md-table--compact tightens the cells',
  Boolean(ruleFor(/\.md-table--compact :where\(th, td\)/)) && Boolean(ruleFor(/\.md-table--compact table/)))
ok('.md-table--dense uses tabular numbers',
  /tabular-nums/.test((ruleFor(/\.md-table--dense/) || ['', ''])[1]))
const cell = ruleFor(/^\.md-block :deep\(th\), \.md-block :deep\(td\)$/)
ok('cell padding is 0.4em 0.75em', Boolean(cell) && /padding:\s*0\.4em 0\.75em/.test(cell[1]), JSON.stringify(cell))
const headRule = ruleFor(/thead th/)
ok('a header row has a 2px strong border',
  Boolean(headRule) && /border-bottom:\s*2px solid var\(--color-border-strong\)/.test(headRule[1]))

// ---- contrast of the zebra band in every palette ------------------------------
const css = readFileSync(join(WUI, 'src/assets/css/variables.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
const blocks = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => [m[1].trim(), m[2]])
const varIn = (body, name) => {
  const m = body.match(new RegExp(`${name}:\\s*([^;]+);`))
  return m ? m[1].trim() : null
}
// the first block that declares a token for a selector (palettes come first)
const tokenOf = (sel, name) => {
  for (const [s, b] of blocks) if (s === sel && varIn(b, name)) return varIn(b, name)
  return null
}
const palettes = blocks.map(([s]) => s)
  .filter((s, i, a) => /^:root(\[data-theme="[a-z-]+"\])?$/.test(s) && a.indexOf(s) === i && tokenOf(s, '--color-bg'))
ok('variables.css declares 8 palettes', palettes.length === 8, JSON.stringify(palettes))

const rgba = (v) => {
  if (!v) return null
  if (v.startsWith('#')) return [1, 3, 5].map((i) => parseInt(v.slice(i, i + 2), 16)).concat(1)
  const m = v.match(/rgba?\(([^)]+)\)/)
  if (!m) return null
  const p = m[1].split(',').map(Number)
  return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1]
}
const over = (top, base) => base.map((c, i) => (i < 3 ? c * (1 - top[3]) + top[i] * top[3] : 1))
const lin = (c) => { const s = c / 255; return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4 }
const lum = ([r, g, b]) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
const contrast = (a, b) => {
  const x = lum(a); const y = lum(b)
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
}
const veilFor = (sel) => rgba(tokenOf(/light/.test(sel) ? ':root[data-theme^="light"]' : ':root', '--color-row-alt'))

for (const sel of palettes) {
  const veil = veilFor(sel)
  for (const token of ['--color-bg', '--color-surface']) {
    const base = rgba(tokenOf(sel, token))
    if (!veil || !base) { ok(`${sel} ${token}: tokens resolve`, false, JSON.stringify({ veil, base })); continue }
    const oddCard = base
    const evenCard = over(veil, base)
    const onOdd = contrast(oddCard, over(veil, oddCard))
    const onEven = contrast(evenCard, over(veil, evenCard))
    ok(`${sel} on ${token}: zebra band vs row >= 1.10 on an odd card (${onOdd.toFixed(3)}) and an even card (${onEven.toFixed(3)})`,
      onOdd >= 1.10 && onEven >= 1.10)
  }
}

console.log(failed ? `FAIL: ${failed} check(s) failed` : 'markdown-table-zebra: all checks passed')
process.exit(failed ? 1 : 0)
