// The two i18n ratchets (SPL-2267): coded counts, no judgement.
//
// Gate A, untranslated values: per locale, the en.json values it still holds
// verbatim. A value counts when, with {placeholders} and URLs removed, it has
// a 3+ letter word; i18n/i18n-keep-english.json lists the values and keys that
// stay English on purpose (brand names, codes), each with its reason.
//
// Gate B, hard-coded UI text: per file under src/, the user-visible literals
// that bypass the translation set: .vue template text (outside {{ }}), static
// title/placeholder/aria-label/alt/label attributes, and string literals
// passed to alert/confirm/prompt in .vue and .ts code.
//
// Each count is held by a baseline (i18n/i18n-untranslated-baseline.json,
// i18n/i18n-raw-text-baseline.json). The unit tests fail when a count goes
// ABOVE its baseline; lower is fine, so the translation and refactor lanes
// only ever lower it. Re-measure:
//   node src/node/i18n/i18n-gates.mjs untranslated   # per locale counts
//   node src/node/i18n/i18n-gates.mjs raw            # per file counts
//   node src/node/i18n/i18n-gates.mjs raw --list     # markdown list, 3 examples
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

export const WUI = join(dirname(fileURLToPath(import.meta.url)), '../../..')
export const LOCALES_DIR = join(WUI, 'i18n/locales')
export const KEEP_FILE = join(WUI, 'i18n/i18n-keep-english.json')
export const UNTRANSLATED_BASELINE = join(WUI, 'i18n/i18n-untranslated-baseline.json')
export const RAW_TEXT_BASELINE = join(WUI, 'i18n/i18n-raw-text-baseline.json')
export const SRC = join(WUI, 'src')

const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'))
const WORD = /[A-Za-z]{3,}/

export function flatten(d, prefix = '', out = {}) {
  for (const [k, v] of Object.entries(d)) {
    const full = prefix ? `${prefix}.${k}` : k
    if (v && typeof v === 'object' && !Array.isArray(v)) flatten(v, full, out)
    else out[full] = v
  }
  return out
}

// "a 3+ letter word after removing {placeholders} and URLs"
export const hasWord = (s) =>
  WORD.test(s.replace(/https?:\/\/\S+/g, '').replace(/\{[^}]*\}/g, ''))

// Gate A. en and loc are flat {key: value}; keep is the parsed allow-list.
export function untranslatedKeys(en, loc, keep) {
  const values = keep.values || {}
  const keys = keep.keys || {}
  return Object.keys(en).filter((k) => {
    const v = en[k]
    return typeof v === 'string' && loc[k] === v && hasWord(v) && !(v in values) && !(k in keys)
  })
}

export function untranslatedCounts(localesDir = LOCALES_DIR, keep = readJson(KEEP_FILE)) {
  const en = flatten(readJson(join(localesDir, 'en.json')))
  const out = {}
  for (const f of readdirSync(localesDir).filter((x) => x.endsWith('.json') && x !== 'en.json').sort()) {
    const keys = untranslatedKeys(en, flatten(readJson(join(localesDir, f))), keep)
    out[f.replace(/\.json$/, '')] = { count: keys.length, keys }
  }
  return out
}

// The outermost <template> block of an SFC, or '' when it has none.
export function templateOf(sfc) {
  const open = sfc.search(/<template(\s[^>]*)?>/)
  const close = sfc.lastIndexOf('</template>')
  if (open < 0 || close < open) return ''
  return sfc.slice(sfc.indexOf('>', open) + 1, close)
}

const STATIC_ATTR = /(^|\s)(title|placeholder|aria-label|alt|label)\s*=\s*("([^"]*)"|'([^']*)')/g
const clean = (s) => s.replace(/&[a-zA-Z#0-9]+;/g, ' ').replace(/\s+/g, ' ').trim()

// The index of the '>' closing the tag opened at i, quote-aware, so
// `v-if="a > b"` stays inside the tag.
function tagEnd(tpl, i) {
  let q = null
  for (let j = i + 1; j < tpl.length; j++) {
    const c = tpl[j]
    if (q) q = c === q ? null : q
    else if (c === '"' || c === "'") q = c
    else if (c === '>') return j
  }
  return tpl.length
}

function attrHits(tag, hits) {
  for (const m of tag.matchAll(STATIC_ATTR)) {
    const v = clean(m[4] ?? m[5] ?? '')
    if (hasWord(v)) hits.push(v)
  }
}

// Gate B, template half: text nodes and static user-visible attributes. A tiny
// tokenizer: tags are skipped quote-aware, {{ }} and <!-- --> are skipped in text.
export function templateHits(tpl) {
  const hits = []
  let i = 0
  let text = ''
  const flush = () => { const t = clean(text); if (hasWord(t)) hits.push(t); text = '' }
  while (i < tpl.length) {
    if (tpl.startsWith('<!--', i)) { const e = tpl.indexOf('-->', i); i = e < 0 ? tpl.length : e + 3; continue }
    if (tpl.startsWith('{{', i)) { const e = tpl.indexOf('}}', i); text += ' '; i = e < 0 ? tpl.length : e + 2; continue }
    if (tpl[i] === '<' && /[A-Za-z/!]/.test(tpl[i + 1] || '')) {
      flush()
      const j = tagEnd(tpl, i)
      attrHits(tpl.slice(i, j + 1), hits)
      i = j + 1
      continue
    }
    text += tpl[i++]
  }
  flush()
  return hits
}

// Gate B, script half: a literal message to a browser dialog.
const DIALOG = /\b(?:alert|confirm|prompt)\(\s*(['"`])((?:\\.|(?!\1).)*)\1/g
export function scriptHits(code) {
  const hits = []
  for (const m of code.matchAll(DIALOG)) {
    const v = clean(m[2].replace(/\$\{[^}]*\}/g, ''))
    if (hasWord(v)) hits.push(v)
  }
  return hits
}

export function rawTextHits(file) {
  const src = readFileSync(file, 'utf8')
  if (!file.endsWith('.vue')) return scriptHits(src)
  const tpl = templateOf(src)
  return [...templateHits(tpl), ...scriptHits(src.replace(tpl, ''))]
}

function walk(dir, out = []) {
  for (const n of readdirSync(dir).sort()) {
    const p = join(dir, n)
    if (statSync(p).isDirectory()) walk(p, out)
    else if (/\.(vue|ts)$/.test(n) && !n.endsWith('.d.ts')) out.push(p)
  }
  return out
}

// {relative path: [hit, ...]} for every file with at least one hit
export function rawTextScan(srcDir = SRC) {
  const out = {}
  for (const f of walk(srcDir)) {
    const hits = rawTextHits(f)
    if (hits.length) out[relative(WUI, f)] = hits
  }
  return out
}

// Ratchet compare: the names whose count is above baseline (a missing name = 0).
export function overBaseline(counts, baseline) {
  return Object.entries(counts)
    .filter(([name, n]) => n > (baseline[name] ?? 0))
    .map(([name, n]) => ({ name, count: n, baseline: baseline[name] ?? 0 }))
}

export function rawTextMarkdown(scan) {
  const rows = Object.entries(scan).sort((a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0]))
  const total = rows.reduce((s, [, h]) => s + h.length, 0)
  const lines = [`Total: ${total} hard-coded strings in ${rows.length} files.`, '',
    '| # | file | count | examples |', '|---|---|---|---|']
  rows.forEach(([f, h], i) => {
    const ex = h.slice(0, 3).map((s) => `"${s.slice(0, 60).replace(/\|/g, '\\|')}"`).join(', ')
    lines.push(`| ${i + 1} | \`${f}\` | ${h.length} | ${ex} |`)
  })
  return lines.join('\n') + '\n'
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [cmd, flag] = process.argv.slice(2)
  const counts = (o, f) => JSON.stringify(Object.fromEntries(Object.entries(o).map(([k, v]) => [k, f(v)])), null, 2)
  if (cmd === 'untranslated') console.log(counts(untranslatedCounts(), (v) => v.count))
  else if (cmd === 'raw' && flag === '--list') process.stdout.write(rawTextMarkdown(rawTextScan()))
  else if (cmd === 'raw') console.log(counts(rawTextScan(), (h) => h.length))
  else {
    console.error('usage: i18n-gates.mjs untranslated | raw [--list]')
    process.exit(2)
  }
}
