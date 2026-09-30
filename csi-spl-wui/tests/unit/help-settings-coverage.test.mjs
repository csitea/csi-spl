// Help drift guard (CLE-77785): the help page csi-spl-doc/doc/help/user-settings.md
// must document every settings surface the WUI actually exposes. help-sync
// guards that the served copy MATCHES the doc source; this guards that the doc
// SOURCE keeps up with the code, so a new settings section (or a renamed enum)
// can't ship with stale help nobody noticed.
//
// It reads the truth from the code — the nav arrays and the option enums the
// settings components render — and fails naming what the help forgot. When you
// add a section to SETTINGS_SECTIONS / TENANT_SETTINGS_SECTIONS, or a value to
// SOUND_NAMES / CLOSE_BUTTONS / SUBMIT_KEYS, or a shipped locale, document it in
// user-settings.md and this passes again.
//
// Run: node tests/unit/help-settings-coverage.test.mjs
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { HELP_SRC } from '../../src/node/help/sync-help.mjs'
import { SETTINGS_SECTIONS } from '../../src/utils/settings-nav.mjs'
import { TENANT_SETTINGS_SECTIONS } from '../../src/utils/tenant-settings-nav.mjs'
import { SOUND_NAMES } from '../../src/utils/notify.mjs'
import { SUBMIT_KEYS } from '../../src/utils/submit-key.mjs'
import { CLOSE_BUTTONS } from '../../src/utils/view-prefs.mjs'
import { RAIL_TABS } from '../../src/utils/rail-order.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

/* Every left-rail tab must be explained by a help page. The map names the page
   (a slug in doc/help) and a keyword that page must contain; a RAIL_TABS id with
   NO entry here fails, so a new tab cannot ship without a help page + mapping.
   Several tabs share one page (channels/dm/flow → channels-and-direct-messages). */
const RAIL_HELP = {
  channels: { slug: 'channels-and-direct-messages', word: 'channel' },
  dm: { slug: 'channels-and-direct-messages', word: 'direct message' },
  issues: { slug: 'issues', word: 'issue' },
  topics: { slug: 'message-levels-and-topics', word: 'topic' },
  flow: { slug: 'channels-and-direct-messages', word: 'flow' },
  archive: { slug: 'archive', word: 'archive' },
  events: { slug: 'events', word: 'event' },
  people: { slug: 'people', word: 'people' },
  agents: { slug: 'agents', word: 'agent' },
  boxes: { slug: 'boxes', word: 'box' },
}

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

/** The shipped UI locale codes, read from nuxt.config's I18N_LOCALES. */
function shippedLocales() {
  const __dirname = dirname(fileURLToPath(import.meta.url))
  const cfg = readFileSync(join(__dirname, '../../nuxt.config.ts'), 'utf8')
  const block = /const I18N_LOCALES = \[([\s\S]*?)\n\]/.exec(cfg)
  if (!block) return []
  return [...block[1].matchAll(/code:\s*"([a-z-]+)"/g)].map((m) => m[1])
}

console.log('help-settings-coverage')
const page = join(HELP_SRC, 'user-settings.md')
if (!existsSync(page)) {
  /* a csi-spl-wui-only checkout (the image build) has no doc tree */
  console.log('  SKIP csi-spl-doc/doc/help/user-settings.md is not in this checkout')
} else {
  const md = readFileSync(page, 'utf8')
  const low = md.toLowerCase()

  /* every user settings section is reachable by its /settings/<id> route, so
     the doc must name that route (the section headings carry it). */
  for (const s of SETTINGS_SECTIONS) {
    ok(`documents /settings/${s.id}`, md.includes(`/settings/${s.id}`),
      `SETTINGS_SECTIONS has "${s.id}" but user-settings.md never names /settings/${s.id}`)
  }

  /* the tenant (workspace) settings area and each of its sections */
  ok('documents the /tenant-settings area', md.includes('/tenant-settings'),
    'TENANT_SETTINGS_SECTIONS exist but user-settings.md never names /tenant-settings')
  for (const s of TENANT_SETTINGS_SECTIONS) {
    ok(`documents tenant section "${s.id}"`, new RegExp(`\\b${s.id}\\b`, 'i').test(low),
      `TENANT_SETTINGS_SECTIONS has "${s.id}" but user-settings.md never mentions it`)
  }

  /* the notification chime sounds the picker offers */
  for (const name of SOUND_NAMES) {
    ok(`documents notification sound "${name}"`, new RegExp(`\\b${name}\\b`, 'i').test(low),
      `SOUND_NAMES has "${name}" but user-settings.md never names it`)
  }

  /* the two Enter behaviours and the two close-button styles */
  ok('documents both submit-key modes (Enter / Ctrl-or-Cmd+Enter)',
    SUBMIT_KEYS.includes('enter') && SUBMIT_KEYS.includes('ctrl-enter') &&
    /\benter\b/i.test(low) && /ctrl\/cmd \+ enter|ctrl\/cmd\+enter|ctrl \+ enter/i.test(low),
    `SUBMIT_KEYS=${JSON.stringify(SUBMIT_KEYS)}`)
  for (const b of CLOSE_BUTTONS) {
    ok(`documents close-button style "${b}"`, new RegExp(`\\b${b}\\b`, 'i').test(low),
      `CLOSE_BUTTONS has "${b}" but user-settings.md never names it`)
  }

  /* every shipped language, and the count the doc claims, stay in step with
     nuxt.config's I18N_LOCALES — the exact drift CLE-77785 fixed (the doc had
     listed a wholly different language set). */
  const locales = shippedLocales()
  ok('reads the shipped locales from nuxt.config', locales.length >= 2, JSON.stringify(locales))
  for (const code of locales) {
    ok(`documents locale "${code}"`, new RegExp('`' + code + '`').test(md),
      `nuxt.config ships "${code}" but the language table never lists \`${code}\``)
  }
  const claim = /\*\*(\d+) languages\*\*/.exec(md)
  ok('the "N languages" claim matches the shipped count',
    Boolean(claim) && Number(claim[1]) === locales.length,
    claim ? `doc says ${claim[1]}, code ships ${locales.length}` : 'no "**N languages**" claim in the doc')

  /* CONTROL: a section id the WUI does NOT expose must read as missing, so the
     checks above discriminate rather than always passing. */
  ok('CONTROL an unknown section route is absent', !md.includes('/settings/bogus-section'))
  ok('CONTROL a real section route is present', md.includes(`/settings/${SETTINGS_SECTIONS[0].id}`))

  /* every left-rail tab has a help page that names it */
  for (const tab of RAIL_TABS) {
    const map = RAIL_HELP[tab.id]
    if (!map) {
      ok(`rail tab "${tab.id}" has a help page`, false,
        `RAIL_TABS has "${tab.id}" but no RAIL_HELP mapping — add a help page and map it`)
      continue
    }
    const p = join(HELP_SRC, `${map.slug}.md`)
    const has = existsSync(p) && readFileSync(p, 'utf8').toLowerCase().includes(map.word)
    ok(`rail tab "${tab.id}" is documented in ${map.slug}.md`, has,
      `${map.slug}.md is missing or never mentions "${map.word}" for the "${tab.id}" tab`)
  }
  /* CONTROL: an id that is not a rail tab has no mapping obligation */
  ok('CONTROL RAIL_HELP has no stray non-tab entries',
    Object.keys(RAIL_HELP).every((id) => RAIL_TABS.some((t) => t.id === id)),
    `RAIL_HELP maps ids that are not RAIL_TABS: ${Object.keys(RAIL_HELP).filter((id) => !RAIL_TABS.some((t) => t.id === id)).join(', ')}`)
}

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.log(`help-settings-coverage: ${failed} FAILED`)
  process.exit(1)
}
console.log('help-settings-coverage: all passed')
