// A colour in a component is a token from assets/css/variables.css, not a hex
// literal (CLE-77915, refactor item 12). The files below keep literals ON
// PURPOSE and say why; any other .vue with a #rgb / #rrggbb fails.
//
// Run: node tests/unit/css-color-tokens.test.mjs
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')

const ALLOWED = {
  'src/components/SocialAuthButtons.vue': 'the providers\' own logo colours (brand rules)',
  'src/components/ThemeToggle.vue': 'each swatch previews ANOTHER theme, so it cannot read the current one',
  'src/layouts/login.vue': 'the sign-in wallpaper and its glow artwork',
  'src/components/MessageCard.vue': '#000 is a mask alpha, not a colour',
  'src/components/ChannelSidebar.vue': '#000 is the darkening operand of color-mix',
  'src/components/MessageComposer.vue': 'file-kind colours: move to --color-file-* once CLE-77917 lands',
}

function walk(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else if (e.name.endsWith('.vue')) out.push(p)
  }
  return out
}

let failed = 0
let seen = 0
for (const f of walk(join(WUI, 'src'))) {
  const rel = relative(WUI, f)
  const css = (readFileSync(f, 'utf8').match(/<style[\s\S]*?<\/style>/g) || []).join('\n').replace(/\/\*[\s\S]*?\*\//g, '')
  const hits = css.match(/#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b/g) || []
  seen += hits.length
  if (hits.length && !ALLOWED[rel]) { failed++; console.log(`  FAIL ${rel}: ${hits.length} hex colour(s) (${hits.slice(0, 3).join(', ')}) - use a --color-* token from assets/css/variables.css`) }
}
for (const rel of Object.keys(ALLOWED)) {
  try { readFileSync(join(WUI, rel)) } catch { failed++; console.log(`  FAIL ALLOWED names ${rel}, which does not exist - delete its line`) }
}
if (seen === 0) { failed++; console.log('  FAIL saw no hex colour at all: the scan is blind (the allowed files carry some)') }
console.log(failed ? `\ncss-color-tokens: ${failed} FAILED` : `css-color-tokens: ${seen} literals, all in the ${Object.keys(ALLOWED).length} allowed files`)
process.exit(failed ? 1 : 0)
