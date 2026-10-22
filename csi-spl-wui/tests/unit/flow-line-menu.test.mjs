// r17-08: the Flow list's row menu lives in composables/useFlowLineMenu.ts.
// No e2e drives Shift+F10 on a Flow row or an AI action on a folded line, so
// these pins hold the two lines a refactor could drop unseen.
// Run: node tests/unit/flow-line-menu.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const menu = src('src/composables/useFlowLineMenu.ts')

describe('useFlowLineMenu', () => {
  it('the menu key and Shift+F10 open a row menu (F10 alone does not)', () => {
    assert.match(menu, /ev\.key === 'ContextMenu' \|\| \(ev\.key === 'F10' && ev\.shiftKey\)/)
  })
  it('an AI action on a topic line marks the line read before it runs', () => {
    assert.match(menu, /id\.startsWith\('ai-'\) && line\.task_id\) \{\s*flow\.markOpened\(line\.key\)\s*aiError\.value = await aiList\.runTopic\(id, line\.task_id\)/)
  })
  it('FlowList takes its menu from the composable, its template unchanged', () => {
    const list = src('src/components/FlowList.vue')
    assert.match(list, /useFlowLineMenu\(\{ flow, listEl, stack, isLine, lineSummary, openLine, openKey \}\)/)
    assert.match(list, /@menu="onMenu"[\s\S]*@press="onPress"[\s\S]*@keydown="onKey"/)
    assert.match(list, /@choose="onMenuChoose"/)
  })
})
