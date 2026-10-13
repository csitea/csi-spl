// SPL-1055: the WUI lint gate (`pnpm run lint`, eslint.config.mjs) and its
// red controls, in the unit suite so CI (`pnpm run test:unit`) holds it.
//
// 1. the shipped tree lints clean (0 problems, warnings included)
// 2. CONTROL a planted `any` in a .ts and in a .vue fails
//    (@typescript-eslint/no-explicit-any, SPL-1051)
// 3. CONTROL a planted v-html fails (vue/no-v-html, SPL-1053)
// 4. the per-line disables may only shrink: today one, the blog body
//    (pages/blog.vue, SAFE: markdownToHtml + build-time hostile refusal),
//    and none for no-explicit-any
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { ESLint } from 'eslint'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const eslint = new ESLint({ cwd: WUI })
const rulesOf = (results) => results.flatMap((r) => r.messages.map((m) => m.ruleId || m.message))

const tree = await eslint.lintFiles(['src'])
const problems = tree.filter((r) => r.errorCount + r.warningCount > 0)
ok('the shipped src lints clean', problems.length === 0,
  problems.map((r) => `${relative(WUI, r.filePath)}: ${rulesOf([r]).join(', ')}`).join(' | '))
ok('lint covers .ts and .vue files', tree.some((r) => r.filePath.endsWith('.ts')) && tree.some((r) => r.filePath.endsWith('.vue')))

const plant = async (text, rel) => rulesOf(await eslint.lintText(text, { filePath: join(WUI, rel) }))
ok('CONTROL a planted `any` in a .ts fails', (await plant('export const x: any = 1\n', 'src/utils/planted.ts')).includes('@typescript-eslint/no-explicit-any'))
ok('CONTROL a planted `as any` in a .vue fails',
  (await plant('<template><p>{{ x }}</p></template>\n<script setup lang="ts">\nconst x = 1 as any\n</script>\n', 'src/components/Planted.vue'))
    .includes('@typescript-eslint/no-explicit-any'))
ok('CONTROL a planted v-html fails',
  (await plant('<template><div v-html="x" /></template>\n<script setup lang="ts">\nconst x = \'<img src=x onerror=alert(1)>\'\n</script>\n', 'src/components/Planted.vue'))
    .includes('vue/no-v-html'))
ok('a clean .vue passes', (await plant('<template><p>{{ x }}</p></template>\n<script setup lang="ts">\nconst x: unknown = 1\n</script>\n', 'src/components/Planted.vue')).length === 0)

function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]))
}
const disables = walk(join(WUI, 'src'))
  .filter((p) => /\.(ts|vue)$/.test(p))
  .flatMap((p) => readFileSync(p, 'utf8').split('\n')
    .filter((l) => /eslint-disable/.test(l) && /no-v-html|no-explicit-any/.test(l))
    .map(() => relative(WUI, p)))
const ALLOWED = ['src/pages/blog.vue']
ok(`per-line disables only shrink (allowed: ${ALLOWED.join(', ')})`, disables.every((p) => ALLOWED.includes(p)) && disables.length <= ALLOWED.length, disables.join(', '))

if (failed) { console.log(`\neslint-gate: ${failed} failed`); process.exit(1) }
console.log('\neslint-gate: all passed')
