// Theme names for the palette picker, all 19 locales.
// EN is the lead's exact string. Every other locale differs.
// theme.to_light / theme.to_dark went with the sun/moon toggle.
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const dir = join(dirname(fileURLToPath(import.meta.url)), '../../i18n/locales')
const KEYS = ['theme.picker', 'theme.light_violet', 'theme.light_green', 'theme.light_yellow', 'theme.light_orange', 'theme.light_red']
const KEPT = ['theme.light', 'theme.dark']
const GONE = ['theme.to_light', 'theme.to_dark']
const EN = {
  'theme.picker': 'Choose a theme',
  'theme.light_violet': 'Light violet',
  'theme.light_green': 'Light green',
  'theme.light_yellow': 'Light yellow',
  'theme.light_orange': 'Light orange',
  'theme.light_red': 'Light red',
  'theme.light': 'Light',
  'theme.dark': 'Dark',
}
const EXPECT = {
  bg: { picker: 'Изберете тема', light_violet: 'Светловиолетова', light_green: 'Светлозелена', light_yellow: 'Светложълта' , light_orange: "Светлооранжева", light_red: "Светлочервена" },
  el: { picker: 'Επιλέξτε θέμα', light_violet: 'Φωτεινό βιολετί', light_green: 'Φωτεινό πράσινο', light_yellow: 'Φωτεινό κίτρινο' , light_orange: "Φωτεινό πορτοκαλί", light_red: "Φωτεινό κόκκινο" },
  en: { picker: 'Choose a theme', light_violet: 'Light violet', light_green: 'Light green', light_yellow: 'Light yellow' , light_orange: "Light orange", light_red: "Light red" },
  es: { picker: 'Elige un tema', light_violet: 'Violeta claro', light_green: 'Verde claro', light_yellow: 'Amarillo claro' , light_orange: "Naranja claro", light_red: "Rojo claro" },
  et: { picker: 'Vali teema', light_violet: 'Hele violett', light_green: 'Hele roheline', light_yellow: 'Hele kollane' , light_orange: "Hele oranž", light_red: "Hele punane" },
  fi: { picker: 'Valitse teema', light_violet: 'Vaalea violetti', light_green: 'Vaalea vihreä', light_yellow: 'Vaalea keltainen' , light_orange: "Vaalea oranssi", light_red: "Vaalea punainen" },
  he: { picker: 'בחרו ערכת נושא', light_violet: 'סגול בהיר', light_green: 'ירוק בהיר', light_yellow: 'צהוב בהיר' , light_orange: "כתום בהיר", light_red: "אדום בהיר" },
  lt: { picker: 'Pasirinkite temą', light_violet: 'Šviesi violetinė', light_green: 'Šviesi žalia', light_yellow: 'Šviesi geltona' , light_orange: "Šviesi oranžinė", light_red: "Šviesi raudona" },
  lv: { picker: 'Izvēlieties motīvu', light_violet: 'Gaiši violets', light_green: 'Gaiši zaļš', light_yellow: 'Gaiši dzeltens' , light_orange: "Gaiši oranžs", light_red: "Gaiši sarkans" },
  mk: { picker: 'Изберете тема', light_violet: 'Светловиолетова', light_green: 'Светлозелена', light_yellow: 'Светложолта' , light_orange: "Светлопортокалова", light_red: "Светлоцрвена" },
  nl: { picker: 'Kies een thema', light_violet: 'Lichtviolet', light_green: 'Lichtgroen', light_yellow: 'Lichtgeel' , light_orange: "Lichtoranje", light_red: "Lichtrood" },
  pl: { picker: 'Wybierz motyw', light_violet: 'Jasny fiolet', light_green: 'Jasny zielony', light_yellow: 'Jasny żółty' , light_orange: "Jasny pomarańczowy", light_red: "Jasny czerwony" },
  ro: { picker: 'Alegeți o temă', light_violet: 'Violet deschis', light_green: 'Verde deschis', light_yellow: 'Galben deschis' , light_orange: "Portocaliu deschis", light_red: "Roșu deschis" },
  ru: { picker: 'Выберите тему', light_violet: 'Светло-фиолетовая', light_green: 'Светло-зелёная', light_yellow: 'Светло-жёлтая' , light_orange: "Светло-оранжевая", light_red: "Светло-красная" },
  sk: { picker: 'Vyberte motív', light_violet: 'Svetlofialový', light_green: 'Svetlozelený', light_yellow: 'Svetložltý' , light_orange: "Svetlooranžový", light_red: "Svetločervený" },
  sr: { picker: 'Izaberite temu', light_violet: 'Svetloljubičasta', light_green: 'Svetlozelena', light_yellow: 'Svetložuta' , light_orange: "Svetlonarandžasta", light_red: "Svetlocrvena" },
  sv: { picker: 'Välj ett tema', light_violet: 'Ljusviolett', light_green: 'Ljusgrönt', light_yellow: 'Ljusgult' , light_orange: "Ljusorange", light_red: "Ljusröd" },
  tr: { picker: 'Bir tema seçin', light_violet: 'Açık mor', light_green: 'Açık yeşil', light_yellow: 'Açık sarı' , light_orange: "Açık turuncu", light_red: "Açık kırmızı" },
  uk: { picker: 'Виберіть тему', light_violet: 'Світло-фіолетова', light_green: 'Світло-зелена', light_yellow: 'Світло-жовта' , light_orange: "Світло-помаранчева", light_red: "Світло-червона" },
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
  for (const key of GONE) {
    flat[key] === undefined ? pass(code + ' no ' + key) : fail(code + ' no ' + key, 'still there')
  }
  for (const leaf of ['picker', 'light_violet', 'light_green', 'light_yellow', 'light_orange', 'light_red']) {
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
