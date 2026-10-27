// HUM-10 t1 4d6bc718 (SPL-3871): the blog's language control is the app's
// own LanguageSwitcher (flags, search, keyboard), not a copy of it: blog.vue
// hands it the page's languages and their URLs, and loads it after mount so
// the blog's first download does not grow. The prerendered <details> links
// stay for JS off and a crawler. The browser half: tests/e2e/blog.test.mjs
// (blogSwitcher).
//
// Run: node tests/unit/blog-lang-switcher.test.mjs
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const WUI = join(here, '../..')
let failed = 0
const ok = (name, cond, why = '') => {
  if (cond) console.log(`  OK   ${name}`)
  else { failed++; console.log(`  FAIL ${name} ${why}`) }
}

const blog = readFileSync(join(WUI, 'src/pages/blog.vue'), 'utf8')
const sw = readFileSync(join(WUI, 'src/components/LanguageSwitcher.vue'), 'utf8')
const tpl = /<template>([\s\S]*)<\/template>/.exec(blog)?.[1] || ''

ok('blog.vue renders the app switcher with the page\'s list and language',
  /<component :is="switcher" v-if="switcher" :choices="langMenu" :current="lang"/.test(tpl))
ok('blog.vue loads LanguageSwitcher with a dynamic import, never a static one',
  blog.includes("import('~/components/LanguageSwitcher.vue')") && !/^import\s+LanguageSwitcher\b/m.test(blog))
ok('the dynamic import runs after mount (client only)',
  /onMounted\(\(\) => \{[\s\S]*?import\('~\/components\/LanguageSwitcher\.vue'\)/.test(blog))
ok('the <details> links are the fallback (JS off, a crawler)',
  /<details v-else [^>]*data-test="blog-lang"/.test(tpl) && /:hreflang="l\.code"/.test(tpl))
ok('no inline :style on the blog (CSP)', !/:style=/.test(tpl))

ok('LanguageSwitcher takes a page\'s own choices and current language',
  /defineProps<\{ fill\?: boolean, choices\?: LocaleChoice\[\], current\?: string \}>/.test(sw))
ok('a choice opens its URL as a full load', /window\.location\.assign\(loc\.href\)/.test(sw))
ok('the blog-only de has its flag', /EXTRA_FLAGS[^=]*= \{ de: '🇩🇪' \}/.test(sw))
ok('without choices the app path (useLocaleSwitch) is unchanged', sw.includes('await switchTo(loc.code)') && /if \(!props\.choices\) return uiLocales\.value/.test(sw))
ok('each option names the URL it opens (data-href)', sw.includes(':data-href="loc.href"'))

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs blog-lang-switcher.test.mjs', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nblog-lang-switcher: ok')
