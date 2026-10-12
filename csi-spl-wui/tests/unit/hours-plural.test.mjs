// Spec 107 F1 (c-181 T018 live proof): the Working hours line read "1 days not
// approved" and "Approve 1 days". Both keys are plural messages now, called as
// t(key, { n }, n): one day reads singular, more read plural, in every locale.
// Run: node tests/unit/hours-plural.test.mjs
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { compile, createCoreContext, fallbackWithLocaleChain, resolveValue, translate } from '@intlify/core-base'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const DIR = join(WUI, 'i18n/locales')
const KEYS = ['hours_cal.banner_open', 'hours_cal.approve_open']
let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

const ctxFor = (locale) => createCoreContext({
  locale, messages: { [locale]: JSON.parse(readFileSync(join(DIR, `${locale}.json`), 'utf8')) },
  messageCompiler: compile, messageResolver: resolveValue, localeFallbacker: fallbackWithLocaleChain,
  missingWarn: false, fallbackWarn: false,
})
const say = (ctx, key, n) => translate(ctx, key, { n, at: 'Fri 17:00' }, n)

const en = ctxFor('en')
ok('en banner, one day', say(en, KEYS[0], 1) === '1 day not approved · freezes Fri 17:00', say(en, KEYS[0], 1))
ok('en banner, three days', say(en, KEYS[0], 3) === '3 days not approved · freezes Fri 17:00', say(en, KEYS[0], 3))
ok('en button, one day', say(en, KEYS[1], 1) === 'Approve 1 day', say(en, KEYS[1], 1))
ok('en button, three days', say(en, KEYS[1], 3) === 'Approve 3 days', say(en, KEYS[1], 3))

// ru has three plural forms; the two-form message keeps the plural grammatical
// with the "noun: {n}" shape the catalogue already uses (feed.replies)
const ru = ctxFor('ru')
ok('ru banner, one day', say(ru, KEYS[0], 1) === '1 день не утверждён · заморозка Fri 17:00', say(ru, KEYS[0], 1))
ok('ru banner, three days', say(ru, KEYS[0], 3) === 'Не утверждено дней: 3 · заморозка Fri 17:00', say(ru, KEYS[0], 3))
ok('ru button, one day', say(ru, KEYS[1], 1) === 'Утвердить 1 день', say(ru, KEYS[1], 1))
ok('ru button, three days', say(ru, KEYS[1], 3) === 'Утвердить дни: 3', say(ru, KEYS[1], 3))

// every locale: a two-form message, the count in both forms
for (const f of readdirSync(DIR).filter((x) => x.endsWith('.json'))) {
  const loc = f.replace('.json', '')
  const ctx = ctxFor(loc)
  const raw = JSON.parse(readFileSync(join(DIR, f), 'utf8')).hours_cal
  for (const k of KEYS) {
    const one = say(ctx, k, 1), many = say(ctx, k, 3)
    ok(`${loc} ${k} has a singular and a plural form`, raw[k.split('.')[1]].split(' | ').length === 2 && one.includes('1') && many.includes('3'), `${one} / ${many}`)
  }
}

// the callers pass the count as the plural choice
for (const c of ['src/components/CalendarHoursDay.vue', 'src/components/CalendarHoursPanel.vue']) {
  const src = readFileSync(join(WUI, c), 'utf8')
  const calls = src.match(/t\('hours_cal\.(banner|approve)_open',[^)]*\)/g) || []
  ok(`${c} passes the count as the plural`, calls.length === 2 && calls.every((s) => /\},\s*b(anner)?\.openDays\.length$/.test(s.slice(0, -1).trim())), calls.join(' ; '))
}

if (failed) { console.log(`${failed} failed`); process.exit(1) }
console.log('hours-plural: all OK')
