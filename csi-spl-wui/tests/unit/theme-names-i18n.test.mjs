// Theme names for the palette picker, all 19 locales.
// EN is the lead's exact string. Every other locale differs.
// The old toggle's switch-to strings may leave with the picker commit.
// This suite does not lock them.
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const dir = join(dirname(fileURLToPath(import.meta.url)), '../../i18n/locales')
const KEYS = ['theme.picker', 'theme.light_violet', 'theme.light_green', 'theme.light_yellow']
const KEPT = ['theme.light', 'theme.dark']
const EN = {
  'theme.picker': 'Choose a theme',
  'theme.light_violet': 'Light violet',
  'theme.light_green': 'Light green',
  'theme.light_yellow': 'Light yellow',
  'theme.light': 'Light',
  'theme.dark': 'Dark',
}
const EXPECT = {
  bg: { picker: 'Изберете тема', light_violet: 'Светловиолетова', light_green: 'Светлозелена', light_yellow: 'Светложълта' },
  el: { picker: 'Επιλέξτε θέμα', light_violet: 'Φωτεινό βιολετί', light_green: 'Φωτεινό πράσινο', light_yellow: 'Φωτεινό κίτρινο' },
  en: { picker: 'Choose a theme', light_violet: 'Light violet', light_green: 'Light green', light_yellow: 'Light yellow' },
  es: { picker: 'Elige un tema', light_violet: 'Violeta claro', light_green: 'Verde claro', light_yellow: 'Amarillo claro' },
  et: { picker: 'Vali teema', light_violet: 'Hele violett', light_green: 'Hele roheline', light_yellow: 'Hele kollane' },
  fi: { picker: 'Valitse teema', light_violet: 'Vaalea violetti', light_green: 'Vaalea vihreä', light_yellow: 'Vaalea keltainen' },
  he: { picker: 'בחרו ערכת נושא', light_violet: 'סגול בהיר', light_green: 'ירוק בהיר', light_yellow: 'צהוב בהיר' },
  lt: { picker: 'Pasirinkite temą', light_violet: 'Šviesi violetinė', light_green: 'Šviesi žalia', light_yellow: 'Šviesi geltona' },
  lv: { picker: 'Izvēlieties motīvu', light_violet: 'Gaiši violets', light_green: 'Gaiši zaļš', light_yellow: 'Gaiši dzeltens' },
  mk: { picker: 'Изберете тема', light_violet: 'Светловиолетова', light_green: 'Светлозелена', light_yellow: 'Светложолта' },
  nl: { picker: 'Kies een thema', light_violet: 'Lichtviolet', light_green: 'Lichtgroen', light_yellow: 'Lichtgeel' },
  pl: { picker: 'Wybierz motyw', light_violet: 'Jasny fiolet', light_green: 'Jasny zielony', light_yellow: 'Jasny żółty' },
  ro: { picker: 'Alegeți o temă', light_violet: 'Violet deschis', light_green: 'Verde deschis', light_yellow: 'Galben deschis' },
  ru: { picker: 'Выберите тему', light_violet: 'Светло-фиолетовая', light_green: 'Светло-зелёная', light_yellow: 'Светло-жёлтая' },
  sk: { picker: 'Vyberte motív', light_violet: 'Svetlofialový', light_green: 'Svetlozelený', light_yellow: 'Svetložltý' },
  sr: { picker: 'Izaberite temu', light_violet: 'Svetloljubičasta', light_green: 'Svetlozelena', light_yellow: 'Svetložuta' },
  sv: { picker: 'Välj ett tema', light_violet: 'Ljusviolett', light_green: 'Ljusgrönt', light_yellow: 'Ljusgult' },
  tr: { picker: 'Bir tema seçin', light_violet: 'Açık mor', light_green: 'Açık yeşil', light_yellow: 'Açık sarı' },
  uk: { picker: 'Виберіть тему', light_violet: 'Світло-фіолетова', light_green: 'Світло-зелена', light_yellow: 'Світло-жовта' },
}

function flatten(d, prefix = '') {
  const out = {}
  for (const [k, v] of Object.entries(d)) {
    const full = prefix ? prefix + '.' + k : k
    if (v && typeof v === 'object' && !Array.isArray(v)) Object.assign(out, flatten(v, full))
    else out[full] = v
  }
  return out
}

let failed = 0
const pass = (n) => console.log('  OK   ' + n)
const fail = (n, m) => { failed++; console.log('  FAIL ' + n + ': ' + m) }

const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort()
files.length === 19 ? pass('19 locales') : fail('19 locales', String(files.length))

const flats = {}
for (const f of files) flats[f] = flatten(JSON.parse(readFileSync(join(dir, f), 'utf8')))

const codes = Object.keys(EXPECT).sort()
codes.length === 19 ? pass('19 expected catalogues') : fail('19 expected catalogues', String(codes.length))
files.map((f) => f.replace(/\.json$/, '')).join() === codes.join()
  ? pass('expected codes match locale files')
  : fail('expected codes match locale files', files.join(','))

for (const code of codes) {
  const flat = flats[code + '.json']
  for (const key of KEYS.concat(KEPT)) {
    const v = flat[key]
    typeof v === 'string' && v.trim() ? pass(code + ' ' + key) : fail(code + ' ' + key, 'missing')
    if (typeof v === 'string' && (v.includes('@') || v.includes('<') || v.includes('|'))) {
      fail(code + ' ' + key + ' syntax', v)
    }
  }
  for (const leaf of ['picker', 'light_violet', 'light_green', 'light_yellow']) {
    const got = flat['theme.' + leaf]
    const want = EXPECT[code][leaf]
    got === want ? pass(code + ' exact ' + leaf) : fail(code + ' exact ' + leaf, JSON.stringify(got))
  }
  if (code !== 'en') {
    const same = KEYS.filter((k) => flat[k] === flats['en.json'][k])
    same.length === 0 ? pass(code + ' differs from en') : fail(code + ' differs from en', same.join(','))
  }
}

for (const [k, v] of Object.entries(EN)) {
  flats['en.json'][k] === v ? pass('en exact ' + k) : fail('en exact ' + k, JSON.stringify(flats['en.json'][k]))
}

const suite = runsInUnitSuite(import.meta.url)
suite.ok ? pass('pnpm test runs theme-names-i18n.test.mjs') : fail('pnpm test runs theme-names-i18n.test.mjs', suite.why)

if (failed) {
  console.error(failed + ' failure(s)')
  process.exit(1)
}
console.log('theme-names-i18n ok')
