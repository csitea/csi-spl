// Searchable preferred-locale combobox (donor suite, adapted: the spool
// has no admin user forms; the Settings page carries LanguageSetting).
// Same matcher as the header LanguageSwitcher (localeSearch.ts).
// Run: node tests/unit/locale-combobox.test.mjs
import { readFileSync, existsSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { runsInUnitSuite } from "./lib/in-suite.mjs"

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, "../..")

let failed = 0
const pass = (name) => console.log(`  OK   ${name}`)
const fail = (name, msg) => { failed++; console.log(`  FAIL ${name}: ${msg}`) }

function read(rel) {
  const p = join(WUI, rel)
  if (!existsSync(p)) { fail(`${rel} exists`, "missing"); return "" }
  pass(`${rel} exists`)
  return readFileSync(p, "utf8")
}

function mustInclude(label, hay, needles) {
  for (const m of needles) {
    hay.includes(m) ? pass(`${label} has ${m}`) : fail(`${label} has ${m}`, "missing")
  }
}

console.log("locale-combobox")

const cbx = read("src/components/LocaleCombobox.vue")
if (cbx) {
  mustInclude("LocaleCombobox.vue", cbx, [
    "Combobox",
    "ComboboxInput",
    "ComboboxOptions",
    "ComboboxOption",
    "@/utils/localeSearch",
    "filterLocales",
    "normalizeLocaleQuery",
    '@focus="onFocus"',
    '@mouseup="onMouseUp"',
    "keepFocusSelection",
    "update:modelValue",
    "allowedCodes",
    "max-width: 100%",
    "min-width: 0",
    "nav.lang_search_placeholder",
    "nav.lang_no_matches",
  ])
  if (cbx.includes("<select")) {
    fail("LocaleCombobox is a Combobox", "native select still present")
  } else {
    pass("LocaleCombobox is a Combobox")
  }
}

// The Settings page control (spec 021): same combobox, stores the hub-side
// preferred_locale and, like the donor's account page, does NOT switch the UI
// locale itself — the stored preference is applied after sign-in by
// plugins/preferred-locale.client.ts.
const ls = read("src/components/LanguageSetting.vue")
if (ls) {
  mustInclude("LanguageSetting.vue", ls, [
    "LocaleCombobox",
    'test-prefix="settings-preferred-locale"',
    'v-model="preferredLocale"',
    "savePreferredLocale",
  ])
  for (const forbidden of ["switchLocalePath", "setLocale("]) {
    ls.includes(forbidden)
      ? fail("LanguageSetting does not switch UI locale", "found " + forbidden)
      : pass("LanguageSetting has no " + forbidden)
  }
}

const inSuite = runsInUnitSuite(import.meta.url)
inSuite.ok
  ? pass("pnpm test runs locale-combobox unit")
  : fail("pnpm test runs locale-combobox unit", inSuite.why)

if (failed > 0) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log("\nAll locale-combobox checks passed.")
