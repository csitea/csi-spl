// Refactor round 21 row 04 (SPL-4592): the timing of useSidebarRailNav's
// selectTab, run on the SHIPPED composable (typescript + the real utils, with
// the router and the stores faked). The check reads state in the same tick as
// the call, with no await between: a rail click writes the sidebar's tab and
// starts its navigation at once, so even one microtask added before them turns
// this red. The 600 ms window of rail-order-default T007 cannot see one.
//
// Run: node tests/unit/rail-nav-timing.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const UTILS_URL = pathToFileURL(join(WUI, 'src/utils')).href
const dataUrl = (code) => 'data:text/javascript;base64,' + Buffer.from(code).toString('base64')
const tsToJs = (src) => ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022, verbatimModuleSyntax: false } }).outputText

/* Nuxt auto-imports and the composables and stores this file imports, per test */
const PRELUDE = 'const useRoute = () => globalThis.__rn.route;\n'
  + 'const useLocalePath = () => (p) => "/xx" + p;\n'
  + 'const navigateTo = (to) => globalThis.__rn.navigateTo(to);\n'
  + 'const useMobileStack = () => globalThis.__rn.mobileStack;\n'
  + 'const useSectionExit = () => globalThis.__rn.sectionExit;\n'
  + 'const pane = () => ({ close() {} });\n'
  + 'const useOperatorPane = pane, useLiveFeed = pane, useTopicStore = pane;\n'

const js = tsToJs(readFileSync(join(WUI, 'src/composables/useSidebarRailNav.ts'), 'utf8'))
  .replace(/^import .* from '~\/(composables|stores)\/.*$/gm, '')
  .replaceAll("'~/utils/", `'${UTILS_URL}/`)
const { useSidebarRailNav } = await import(dataUrl(PRELUDE + js))

const val = (value) => ({ value })

function rig({ path = '/t/abc', mobile = false, level = 1, stripOnly = false, tab = 'channels', docsRailOnly = false, target = '/channel/last', navDone = Promise.resolve() } = {}) {
  const calls = { navigated: [], home: 0 }
  globalThis.__rn = {
    route: { path },
    navigateTo: (to) => { calls.navigated.push(to); return navDone },
    mobileStack: { isMobile: val(mobile), level: val(level), home: () => { calls.home += 1 } },
    sectionExit: { target: () => target },
  }
  const refs = { tab: val(tab), holdFlow: val(false), holdSearch: val(true), stripOnly: val(stripOnly), onRailLink: val(false), helpRailOnly: val(false), docsRailOnly: val(docsRailOnly) }
  return { refs, calls, nav: useSidebarRailNav(refs) }
}

describe('selectTab acts in the tick of the click', () => {
  it('writes tab, holdFlow and holdSearch before any microtask', async () => {
    const { refs, nav } = rig()
    const done = nav.selectTab('flow')
    assert.equal(refs.tab.value, 'flow')
    assert.equal(refs.holdFlow.value, true)
    assert.equal(refs.holdSearch.value, false)
    await done
  })

  it('a phone tap on the selected section goes home at once and writes nothing', async () => {
    const { refs, calls, nav } = rig({ mobile: true, level: 2, stripOnly: true, tab: 'issues' })
    const done = nav.selectTab('issues')
    assert.equal(calls.home, 1)
    assert.equal(refs.holdSearch.value, true)
    await done
    assert.deepEqual(calls.navigated, [])
  })

  it('a desktop leave from a section page starts its navigation at once, without the query', async () => {
    const { refs, calls, nav } = rig({ path: '/issues', target: '/channel/last?topic=1' })
    const done = nav.selectTab('channels')
    assert.deepEqual(calls.navigated, ['/channel/last'])
    assert.equal(refs.tab.value, 'channels')
    await done
    assert.deepEqual(calls.navigated, ['/channel/last'])
  })

  it('a section with its own page opens it at once when there is no leave', async () => {
    const { calls, nav } = rig({ path: '/channel/alerts' })
    const done = nav.selectTab('issues')
    assert.deepEqual(calls.navigated, ['/xx/issues'])
    await done
  })

  it('a phone never takes the desktop leave: home at once, no navigation', async () => {
    const { calls, nav } = rig({ path: '/issues', mobile: true, level: 2 })
    const done = nav.selectTab('channels')
    assert.equal(calls.home, 1)
    await done
    assert.deepEqual(calls.navigated, [])
  })
})

describe('sectionLeavePath, through selectTab', () => {
  it('a rail-only page with no way back leaves to the localized lobby', async () => {
    const { calls, nav } = rig({ path: '/workspace/docs', docsRailOnly: true, target: '' })
    await nav.selectTab('flow')
    assert.deepEqual(calls.navigated, ['/xx/lobby'])
  })

  it('a section page with no way back stays', async () => {
    const { calls, nav } = rig({ path: '/issues', target: '' })
    await nav.selectTab('dm')
    assert.deepEqual(calls.navigated, [])
  })

  it('selectTab waits for the leave before it resolves', async () => {
    let release
    const { nav } = rig({ path: '/issues', navDone: new Promise((r) => { release = r }) })
    let resolved = false
    const done = nav.selectTab('channels').then(() => { resolved = true })
    await new Promise((r) => setTimeout(r, 0))
    assert.equal(resolved, false)
    release()
    await done
    assert.equal(resolved, true)
  })
})
