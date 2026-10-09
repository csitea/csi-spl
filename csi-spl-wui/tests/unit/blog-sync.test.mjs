// Spec 111 T002: the blog's build-time copy (src/node/blog/sync-blog.mjs) and
// the /blog/** refusal in render-wui-firebase-json.sh. Section 9 of the spec:
//   9-a  a new post appears in index.json and as a fragment per locale;
//        control: --check exits 1 on a stale copy
//   9-l  the cap in the build: 9 posts committed on one day render exactly 7,
//        the digest among them; control: the same 9 over two days render all
//        9; a back-dated `published`, a draft flipped later and an edit that
//        changes `id` each count on their commit day
//   cap_exempt_tags (owner HUM-10 d940f865, option a): 10 `feature` posts
//        and 7 ordinary ones on one day: all 10 render, the ordinary ones
//        stay capped; control: without the key the feature posts are capped
//   9-c  (script controls) a planted <img src=x onerror=...> and a raw
//        <script> in a post are refused by --check and by the render
//
// Every repo here is a throwaway git repo with pinned commit times.
//
// Run: node tests/unit/blog-sync.test.mjs
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { applyCap, blogCnf, blogDrift, blogFiles, blogLocales, hostile, parseFrontmatter, validateMeta, writeBlog } from '../../src/node/blog/sync-blog.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const REPO = join(WUI, '..')
const SYNC = join(WUI, 'src/node/blog/sync-blog.mjs')
const RENDER = join(REPO, 'csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh')
const LOCALES = ['en', 'fi', 'sv']
const CNF = { tz: 'Europe/Helsinki', cap_per_day: 7, digest_reserved: 1, digest_at: '23:00' }
const scratch = []
const tmp = (p) => { const d = mkdtempSync(join(tmpdir(), p)); scratch.push(d); return d }

function post(id, { lang = 'en', type = 'news', draft = false, published = '', tags = 'release, fleet', body = 'A plain body with a [link](https://example.com/x).' } = {}) {
  return ['---', `id: ${id}`, `lang: ${lang}`, `type: ${type}`, `title: "Post ${id}"`, 'summary: "One sentence."',
    `date: ${id.slice(0, 10)}`, ...(published ? [`published: ${published}`] : []), 'author: m-004', 'agy_review: a-004',
    `tags: [${tags}]`, `draft: ${draft}`, '---', body, ''].join('\n')
}

/** A throwaway repo: commit(files, utc) writes {lang/id.md: text|null} and commits at `utc`. */
function repo() {
  const root = tmp('blog-sync-repo-')
  const src = join(root, 'csi-spl-doc/blog/posts')
  const g = (args, env = {}) => spawnSync('git', ['-C', root, '-c', 'user.name=blog-test', '-c', 'user.email=blog-test@example.com', ...args],
    { encoding: 'utf8', env: { ...process.env, ...env } })
  g(['init', '-q', '-b', 'master'])
  return {
    root, src,
    commit(files, utc) {
      for (const [rel, text] of Object.entries(files)) {
        const p = join(src, rel)
        if (text === null) { g(['rm', '-q', '--', p]); continue }
        mkdirSync(dirname(p), { recursive: true })
        writeFileSync(p, text)
        g(['add', '--', p])
      }
      const r = g(['commit', '-q', '--allow-empty', '-m', 'post'], { GIT_AUTHOR_DATE: utc, GIT_COMMITTER_DATE: utc })
      if (r.status !== 0) throw new Error(r.stderr)
    },
    sync(now = Date.parse('2026-10-20T12:00:00Z'), cnf = CNF) { return blogFiles({ src, root, cnf, locales: LOCALES, now }) },
  }
}

const enIds = (r) => (JSON.parse(r.files.get('index.json')).locales.en || []).map((e) => e.id)
/* Helsinki is UTC+3 in October: 07:00Z = 10:00 local, 20:10Z = 23:10 local */
const at = (day, hhmm) => `${day}T${hhmm}:00Z`

try {
  console.log('blog-sync')

  /* ── the parser and validation ─────────────────────────────────────── */
  const fm = parseFrontmatter(post('2026-10-05-a'))
  ok('frontmatter parses: strings, lists, booleans', fm.meta.title === 'Post 2026-10-05-a' && fm.meta.tags.join() === 'release,fleet' && fm.meta.draft === false)
  let threw = ''
  try { parseFrontmatter(post('2026-10-05-a').replace('draft: false', 'draf: true')) } catch (e) { threw = e.message }
  ok('CONTROL a typo key (draf: true) is refused, never ignored', /unknown key draf/.test(threw), threw)
  ok('a valid copy passes validation', validateMeta(fm.meta, { id: '2026-10-05-a', lang: 'en', locales: LOCALES }).length === 0)
  ok('CONTROL image without image_alt is refused',
    validateMeta({ ...fm.meta, image: '2026-10-05-a.webp' }, { id: '2026-10-05-a', lang: 'en', locales: LOCALES }).includes('image without image_alt'))
  ok('CONTROL an image key that is not <id>.webp is refused',
    validateMeta({ ...fm.meta, image: '../x.webp', image_alt: 'x' }, { id: '2026-10-05-a', lang: 'en', locales: LOCALES }).some((b) => /image \.\.\/x/.test(b)))
  ok('CONTROL an id that is not the file name is refused',
    validateMeta(fm.meta, { id: '2026-10-05-b', lang: 'en', locales: LOCALES }).some((b) => /not the file name/.test(b)))
  ok('CONTROL a lang that is not the dir is refused',
    validateMeta(fm.meta, { id: '2026-10-05-a', lang: 'fi', locales: LOCALES }).some((b) => /not the dir/.test(b)))
  ok('the cnf yields env.blog (or the spec defaults)', (() => { const c = blogCnf(); return c.tz === 'Europe/Helsinki' && c.cap_per_day === 7 && c.digest_reserved === 1 })(), JSON.stringify(blogCnf()))
  ok('the locales are i18n/locales (19)', blogLocales().length === 19 && blogLocales().includes('en'), String(blogLocales().length))

  /* ── 9-c script controls in the sync ───────────────────────────────── */
  ok('a plain post is not hostile', hostile(post('2026-10-05-a')) === '')
  ok('CONTROL <img src=x onerror=...> is refused', hostile('<img src=x onerror=alert(1)>') === 'an on*= attribute')
  ok('CONTROL a raw <script> is refused', hostile('<script>alert(1)</script>') === '<script')
  ok('CONTROL an escaped &lt;script is refused too', hostile('&lt;script&gt;') === '<script')
  ok('CONTROL a javascript: URL is refused (entity-encoded too)', hostile('[x](jav&#97;script:alert(1))') === 'a javascript: URL')
  ok('CONTROL a data: URL is refused', hostile('[x](data:text/html;base64,PHNjcmlwdD4=)') === 'a data: URL')
  ok('prose "data: the facts" is not a data: URL', hostile('Raw data: the facts file') === '')
  {
    const r = repo()
    r.commit({ 'en/2026-10-05-a.md': post('2026-10-05-a', { body: 'Hi <img src=x onerror=alert(1)> there' }),
      'en/2026-10-05-b.md': post('2026-10-05-b', { body: '<script>alert(1)</script>' }),
      'en/2026-10-05-c.md': post('2026-10-05-c') }, at('2026-10-05', '07:00'))
    const s = r.sync()
    ok('CONTROL sync refuses the planted onerror post', s.errors.some((e) => /2026-10-05-a\.md: refused, it holds an on\*= attribute/.test(e)), s.errors.join(' | '))
    ok('CONTROL sync refuses the raw <script> post', s.errors.some((e) => /2026-10-05-b\.md: refused, it holds <script/.test(e)), s.errors.join(' | '))
    ok('a refused post writes no fragment', !s.files.has('en/2026-10-05-a.html') && !s.files.has('en/2026-10-05-b.html') && s.files.has('en/2026-10-05-c.html'))
    const out = tmp('blog-sync-out-')
    const cli = spawnSync(process.execPath, [SYNC, '--check'], { encoding: 'utf8', env: { ...process.env, BLOG_POSTS_DIR: r.src, BLOG_GIT_ROOT: r.root, BLOG_OUT_DIR: out } })
    ok('CONTROL --check exits 1 on the hostile posts', cli.status === 1 && /refused/.test(cli.stderr), `${cli.status} ${cli.stderr}`)
    const w = spawnSync(process.execPath, [SYNC], { encoding: 'utf8', env: { ...process.env, BLOG_POSTS_DIR: r.src, BLOG_GIT_ROOT: r.root, BLOG_OUT_DIR: out } })
    ok('CONTROL the write (generate) also exits 1 and writes nothing', w.status === 1 && !existsSync(join(out, 'index.json')), `${w.status}`)
  }

  /* ── 9-a a new post appears in index.json and per locale ───────────── */
  {
    const r = repo()
    r.commit({ 'en/2026-10-05-a.md': post('2026-10-05-a') }, at('2026-10-05', '07:00'))
    const out = tmp('blog-sync-out-')
    const env = { ...process.env, BLOG_POSTS_DIR: r.src, BLOG_GIT_ROOT: r.root, BLOG_OUT_DIR: out }
    const w1 = spawnSync(process.execPath, [SYNC], { encoding: 'utf8', env })
    ok('sync writes the copy', w1.status === 0 && existsSync(join(out, 'en/2026-10-05-a.html')), w1.stderr)
    r.commit({ 'en/2026-10-06-new.md': post('2026-10-06-new'), 'fi/2026-10-06-new.md': post('2026-10-06-new', { lang: 'fi' }),
      'fi/2026-10-05-a.md': post('2026-10-05-a', { lang: 'fi' }) }, at('2026-10-06', '07:00'))
    const stale = spawnSync(process.execPath, [SYNC, '--check'], { encoding: 'utf8', env })
    ok('CONTROL --check exits 1 on a stale copy and names it', stale.status === 1 && /stale.*en\/2026-10-06-new\.html/.test(stale.stderr), `${stale.status} ${stale.stderr}`)
    const w2 = spawnSync(process.execPath, [SYNC], { encoding: 'utf8', env })
    const fresh = spawnSync(process.execPath, [SYNC, '--check'], { encoding: 'utf8', env })
    ok('after the sync --check passes', w2.status === 0 && fresh.status === 0, fresh.stderr)
    const idx = JSON.parse(readFileSync(join(out, 'index.json'), 'utf8')).locales
    ok('the new post is in index.json, newest first, in en and fi', idx.en.map((e) => e.id).join() === '2026-10-06-new,2026-10-05-a' && idx.fi.map((e) => e.id).join() === '2026-10-06-new,2026-10-05-a', JSON.stringify(idx))
    ok('a fragment per locale copy', existsSync(join(out, 'en/2026-10-06-new.html')) && existsSync(join(out, 'fi/2026-10-06-new.html')) && !existsSync(join(out, 'sv')))
    const html = readFileSync(join(out, 'en/2026-10-06-new.html'), 'utf8')
    ok('the fragment is markdownToHtml: an external link gets rel nofollow', /<a href="https:\/\/example\.com\/x"[^>]* target="_blank" rel="[^"]*noopener[^"]*nofollow/.test(html), html)
    ok('index entries carry the list fields', ['id', 'type', 'title', 'summary', 'date', 'author', 'tags'].every((k) => k in idx.en[0]) && !('agy_review' in idx.en[0]))
    r.commit({ 'en/2026-10-06-new.md': post('2026-10-06-new', { draft: true }) }, at('2026-10-06', '08:00'))
    const d = r.sync()
    ok('a draft: true post is skipped (no entry, no fragment)', !enIds(d).includes('2026-10-06-new') && !d.files.has('en/2026-10-06-new.html'))
    ok('CONTROL a stray locale copy without an en post fails the sync', d.errors.some((e) => /fi\/2026-10-06-new\.md: no live en/.test(e)), d.errors.join(' | '))
  }

  /* ── 9-l the cap in the build ──────────────────────────────────────── */
  const D = '2026-10-10'
  const nine = (r, dayA, dayB = dayA) => {
    for (let i = 1; i <= 8; i++) r.commit({ [`en/${D}-n${i}.md`]: post(`${D}-n${i}`) }, at(i <= 4 ? dayA : dayB, `0${i}:00`))
    r.commit({ [`en/${D}-digest.md`]: post(`${D}-digest`, { type: 'digest' }) }, at(dayB, '20:10'))
  }
  {
    const r = repo()
    nine(r, D)
    const s = r.sync()
    const ids = enIds(s)
    ok('9-l 9 posts on one day render exactly 7', ids.length === 7, ids.join())
    ok('9-l the digest is among them', ids.includes(`${D}-digest`))
    ok('9-l the first 6 others by commit order render', [1, 2, 3, 4, 5, 6].every((i) => ids.includes(`${D}-n${i}`)) && !ids.includes(`${D}-n7`) && !ids.includes(`${D}-n8`))
    ok('9-l the 8th and 9th stay in git, named in the log', s.dropped.map((x) => x.id).sort().join() === `${D}-n7,${D}-n8` && s.dropped.every((x) => x.day === D && /cap of 7/.test(x.why)), JSON.stringify(s.dropped))
  }
  {
    const r = repo()
    nine(r, D, '2026-10-11')
    ok('9-l CONTROL the same 9 over two days render all 9', enIds(r.sync()).length === 9)
  }
  {
    const full = () => { const r = repo(); for (let i = 1; i <= 6; i++) r.commit({ [`en/${D}-n${i}.md`]: post(`${D}-n${i}`) }, at(D, `0${i}:00`)); return r }
    /* back-dated: published + date say 3 days earlier; git says D */
    const r1 = full()
    r1.commit({ 'en/2026-10-07-old.md': post('2026-10-07-old', { published: '2026-10-07T07:00:00Z' }) }, at(D, '09:00'))
    const s1 = r1.sync()
    ok('9-l CONTROL a back-dated published counts on its commit day', !enIds(s1).includes('2026-10-07-old') && s1.dropped.some((x) => x.id === '2026-10-07-old' && x.day === D), JSON.stringify(s1.dropped))
    /* draft flipped later: added as a draft on an empty day, flipped on D */
    const r2 = repo()
    r2.commit({ 'en/2026-10-07-flip.md': post('2026-10-07-flip', { draft: true }) }, at('2026-10-07', '07:00'))
    for (let i = 1; i <= 6; i++) r2.commit({ [`en/${D}-n${i}.md`]: post(`${D}-n${i}`) }, at(D, `0${i}:00`))
    r2.commit({ 'en/2026-10-07-flip.md': post('2026-10-07-flip') }, at(D, '09:00'))
    const s2 = r2.sync()
    ok('9-l CONTROL a draft flipped later counts on the flip day', !enIds(s2).includes('2026-10-07-flip') && s2.dropped.some((x) => x.id === '2026-10-07-flip' && x.day === D), JSON.stringify(s2.dropped))
    /* an edit that changes id: published on an empty day, renamed on D */
    const r3 = repo()
    r3.commit({ 'en/2026-10-07-was.md': post('2026-10-07-was') }, at('2026-10-07', '07:00'))
    for (let i = 1; i <= 6; i++) r3.commit({ [`en/${D}-n${i}.md`]: post(`${D}-n${i}`) }, at(D, `0${i}:00`))
    r3.commit({ 'en/2026-10-07-was.md': null, 'en/2026-10-07-now.md': post('2026-10-07-now') }, at(D, '09:00'))
    const s3 = r3.sync()
    ok('9-l CONTROL an edit that changes id counts on its commit day', !enIds(s3).includes('2026-10-07-now') && s3.dropped.some((x) => x.id === '2026-10-07-now' && x.day === D), JSON.stringify(s3.dropped))
    /* an edit that keeps id and stays live does not count again */
    const r4 = repo()
    r4.commit({ 'en/2026-10-07-keep.md': post('2026-10-07-keep') }, at('2026-10-07', '07:00'))
    for (let i = 1; i <= 6; i++) r4.commit({ [`en/${D}-n${i}.md`]: post(`${D}-n${i}`) }, at(D, `0${i}:00`))
    r4.commit({ 'en/2026-10-07-keep.md': post('2026-10-07-keep', { body: 'edited' }) }, at(D, '09:00'))
    ok('9-l an edit that keeps id is not a new publication', enIds(r4.sync()).length === 7)
    /* a fake digest at 10:00 does not take the reserved slot */
    const r5 = repo()
    r5.commit({ [`en/${D}-digest.md`]: post(`${D}-digest`, { type: 'digest' }) }, at(D, '07:00'))
    const s5 = r5.sync()
    ok('9-l CONTROL a 10:00 digest does not render', !enIds(s5).includes(`${D}-digest`) && /outside 23:00/.test(s5.dropped[0]?.why || ''), JSON.stringify(s5.dropped))
  }
  /* ── cap_exempt_tags: the feature series is not held by the cap ───── */
  {
    const r = repo()
    for (let i = 1; i <= 7; i++) r.commit({ [`en/${D}-n${i}.md`]: post(`${D}-n${i}`) }, at(D, `0${i}:00`))
    for (let i = 10; i <= 19; i++) r.commit({ [`en/${D}-feature-f${i}.md`]: post(`${D}-feature-f${i}`, { tags: 'feature, fleet' }) }, at(D, `${i}:00`))
    const feats = Array.from({ length: 10 }, (_, k) => `${D}-feature-f${k + 10}`)
    const ex = enIds(r.sync(undefined, { ...CNF, cap_exempt_tags: ['feature'] }))
    ok('cap_exempt_tags: 10 feature posts + 7 ordinary on one day: all 10 feature posts render', feats.every((f) => ex.includes(f)), ex.join())
    ok('cap_exempt_tags: the ordinary ones are still capped at 6 + the digest slot (7)', ex.filter((x) => !x.includes('-feature-')).length === 6 && !ex.includes(`${D}-n7`), ex.join())
    const ctl = r.sync(undefined, { ...CNF })
    const cx = enIds(ctl)
    ok('CONTROL without cap_exempt_tags the feature posts are capped again', cx.length === 6 && feats.every((f) => !cx.includes(f)) && ctl.dropped.filter((x) => /cap of 7/.test(x.why)).length === 11, cx.join())
    const dg = repo()
    dg.commit({ [`en/${D}-digest.md`]: post(`${D}-digest`, { type: 'digest', tags: 'feature' }) }, at(D, '07:00'))
    ok('CONTROL an exempt tag does not lift the digest rules', !enIds(dg.sync(undefined, { ...CNF, cap_exempt_tags: ['feature'] })).includes(`${D}-digest`))
    const dir = tmp('blog-sync-cnf-')
    const yml = (extra) => { const f = join(dir, `c${extra.length}.yaml`); writeFileSync(f, `env:\n  blog:\n    cap_per_day: 7\n${extra}    digest_reserved: 1\n`); return f }
    ok('blogCnf reads cap_exempt_tags: [feature]', blogCnf(yml('    cap_exempt_tags: [feature]\n')).cap_exempt_tags.join() === 'feature')
    ok('CONTROL a cnf without the key exempts nothing', blogCnf(yml('')).cap_exempt_tags.length === 0)
    ok('the repo cnf exempts the feature series', blogCnf().cap_exempt_tags.includes('feature'), JSON.stringify(blogCnf()))
  }
  let tzErr = ''
  try { applyCap([], { ...CNF, tz: 'Europe/Nowhere' }) } catch (e) { tzErr = e.message }
  ok('CONTROL an unknown env.blog.tz is refused, never the box zone', /not an IANA zone/.test(tzErr), tzErr)
  ok('the cap counts a post once: applyCap sees ids, never locale copies',
    applyCap([{ id: 'a', type: 'news', at: 1, seq: 0 }], CNF).keep.has('a'))

  /* ── the real tree ─────────────────────────────────────────────────── */
  {
    const s = blogFiles()
    ok('the repo posts sync with no error', s.errors.length === 0, s.errors.join(' | '))
    const out = tmp('blog-sync-out-')
    writeBlog(s.files, out)
    ok('blogDrift is empty right after a write', blogDrift(s.files, out).length === 0)
  }

  /* ── 9-c script controls in the render ─────────────────────────────── */
  {
    const SHELL_JS = 'window.__NUXT__={};window.__NUXT__.config={public:{}}'
    const page = (body, extra = '') => `<!DOCTYPE html><html lang="en"><head><script>${SHELL_JS}</script>${extra}</head><body>${body}<script type="module" src="/_nuxt/a.js"></script></body></html>`
    const render = (files) => {
      const dir = tmp('blog-render-')
      writeFileSync(join(dir, '200.html'), page('<div id="__nuxt"></div>'))
      for (const [rel, body] of Object.entries(files)) { mkdirSync(dirname(join(dir, rel)), { recursive: true }); writeFileSync(join(dir, rel), body) }
      return spawnSync('bash', [RENDER], { encoding: 'utf8', env: { ...process.env, ENV: 'dev', OUT: join(tmp('blog-render-out-'), 'firebase.json'), PUBLIC_DIR: dir } })
    }
    const good = render({ 'blog/2026-10-05-a/index.html': page('<article><p>Fine, see <a href="https://example.com">x</a>.</p></article>') })
    ok('render passes a clean /blog page', good.status === 0, good.stderr)
    const s1 = render({ 'blog/2026-10-05-a/index.html': page('<p>x</p><script>alert(1)</script>') })
    ok('CONTROL render refuses a raw <script> in a /blog page', s1.status !== 0 && /blog.*inline <script> the app shell/.test(s1.stderr), s1.stderr)
    const s2 = render({ 'fi/blog/2026-10-05-a/index.html': page('<p>x <img src=x onerror=alert(1)></p>') })
    ok('CONTROL render refuses <img src=x onerror=...> in a /<lang>/blog page', s2.status !== 0 && /onerror=/.test(s2.stderr), s2.stderr)
    const s3 = render({ 'blog/2026-10-05-a/index.html': page('<p><a href="jav&#97;script:alert(1)">x</a></p>') })
    ok('CONTROL render refuses a javascript: URL in a /blog page', s3.status !== 0 && /javascript: URL/.test(s3.stderr), s3.stderr)
    const s4 = render({ 'blog/index.html': page('<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>') })
    ok('CONTROL render refuses an escaped <script> in /blog', s4.status !== 0 && /holds <script/.test(s4.stderr), s4.stderr)
    const s5 = render({ 'blog/2026-10-05-a/index.html': page('<p>x</p>', '<script src="https://cdn.example.com/x.js"></script>') })
    ok('CONTROL render refuses a script from outside /_nuxt/ in /blog', s5.status !== 0 && /outside \/_nuxt/.test(s5.stderr), s5.stderr)
    const s6 = render({ 'help/index.html': page('<p><a href="javascript:void(0)">x</a></p>') })
    ok('the blog rule leaves non-blog pages to the CSP rules', s6.status === 0, s6.stderr)
  }

  /* ── wiring ────────────────────────────────────────────────────────── */
  const pkg = JSON.parse(readFileSync(join(WUI, 'package.json'), 'utf8'))
  ok('pnpm run generate runs the sync first', /^node src\/node\/blog\/sync-blog\.mjs && (node src\/node\/roadmap\/sync-roadmap\.mjs && )?(node src\/node\/docs\/sync-public-docs\.mjs && )?nuxt generate$/.test(pkg.scripts.generate), pkg.scripts.generate)
  ok('src/public/blog-md/ is git-ignored', /^src\/public\/blog-md\/$/m.test(readFileSync(join(WUI, '.gitignore'), 'utf8')))
  const wf = join(REPO, '.github/workflows/30_wui-build-deploy.yml')
  if (existsSync(wf)) ok('wf 30 deploys on a post commit', /^\s+- 'csi-spl-doc\/blog\/posts\/\*\*'/m.test(readFileSync(wf, 'utf8')))
  const s = runsInUnitSuite(import.meta.url)
  ok('pnpm test runs this suite', s.ok, s.why)
} finally {
  for (const d of scratch) rmSync(d, { recursive: true, force: true })
}

if (failed) { console.log(`blog-sync: ${failed} failed`); process.exit(1) }
console.log('blog-sync: all passed')
