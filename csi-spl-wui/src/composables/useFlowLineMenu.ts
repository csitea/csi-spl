/**
 * The Flow list's row menu (FlowList, r17-08). t1 b6c742f0 (HUM-10 14dc0232:
 * "add those same actions to every msg card in every view"): an entry's
 * menu - right-click, a long press on a phone (the bottom sheet), or the menu
 * key. An AI pick opens the message where it lives, then runs there
 * (composables/useAiListRun.ts). A folded line's entries and its Shift keys
 * share one table (FLOW_LINE_ACTIONS, spec 130). Called in the list's setup,
 * so the long press is cancelled when that component unmounts.
 */
import type { Ref } from 'vue'
import type { FlowEntry } from '~/utils/flow-entries.mjs'
import { flowLineOffered, flowLineTarget } from '~/utils/flow-fold.mjs'
import type { FlowLine } from '~/utils/flow-fold.mjs'
import { FLOW_LINE_ACTIONS, flowShortcutFor, flowShortcutHint, flowShortcutItem } from '~/utils/msg-shortcuts.mjs'
import { useMsgShortcutsHelp, useMsgShortcutsOn } from '~/composables/useMsgShortcuts'
import { writeClipboard } from '~/utils/clipboard.mjs'
import { createLongPress } from '~/utils/touch-ui'
import { useAiListRun } from '~/composables/useAiListRun'
import type { useFlowStore } from '~/stores/flow'
import type { useMobileStack } from '~/composables/useMobileStack'
import type { PointMenuItem } from '~/components/UiPointMenu.vue'

type FlowRow = FlowLine | FlowEntry

export type FlowLineMenuOptions = {
  flow: ReturnType<typeof useFlowStore>
  listEl: Ref<{ focus: () => void, rowEl: (key: string) => HTMLElement | null | undefined } | null>
  stack: ReturnType<typeof useMobileStack>
  isLine: (r: FlowRow | null | undefined) => r is FlowLine
  lineSummary: (l: FlowLine) => string
  openLine: (line: FlowLine, to: 'message' | 'issue' | 'release') => Promise<void>
  openKey: (key: string) => Promise<void>
}

type MenuState = { row: FlowRow | null, x: number, y: number }

/** What the open menu shows: a folded line's entries and its AI subject, else the message's. */
function flowMenuView(menu: MenuState, isLine: FlowLineMenuOptions['isLine']) {
  const MENU_ITEMS: PointMenuItem[] = [{ id: 'original', icon: 'open', labelKey: 'search.menu.original' }]
  const menuLine = computed(() => (isLine(menu.row) ? menu.row : null))
  /* a folded line: the entries it offers (flowLineOffered), each with its Shift key */
  const menuItems = computed<PointMenuItem[]>(() => {
    const line = menuLine.value
    if (!line) return MENU_ITEMS
    const offered = flowLineOffered(line)
    return FLOW_LINE_ACTIONS.filter((a) => offered.includes(a.id))
      .map((a) => ({ id: a.id, icon: a.icon, labelKey: a.labelKey, keyHint: flowShortcutHint(a.id) }))
  })
  /* the AI actions act on a topic line's topic (aiSubject 'topic'); a release line has none */
  const menuAi = computed(() => {
    const line = menuLine.value
    if (!line) return menu.row
    return line.kind === 'release' ? null : { ai_kind: 'topic', task_id: line.task_id, title: line.title || line.text || '' }
  })
  return { menuLine, menuItems, menuAi }
}

/** A long press on a row (a phone) opens its menu; cancelled when the list unmounts. */
function useRowLongPress(entryOf: (key: string) => FlowRow | null, openMenuAt: (row: FlowRow, x: number, y: number) => void) {
  let pressRow: FlowRow | null = null
  const longPress = createLongPress({
    onPress: (x, y) => {
      if (!pressRow) return
      if (typeof navigator !== 'undefined' && typeof navigator.vibrate === 'function') navigator.vibrate(10)
      openMenuAt(pressRow, x, y)
    },
  })
  onBeforeUnmount(() => longPress.cancel())
  function onPress(key: string, ev: PointerEvent) {
    pressRow = entryOf(key)
    longPress.down(ev)
    const el = ev.currentTarget as HTMLElement | null
    if (!el) return
    const off = () => { el.removeEventListener('pointermove', longPress.move); el.removeEventListener('pointerup', up); el.removeEventListener('pointercancel', cancel) }
    const up = () => { longPress.up(); off() }
    const cancel = () => { longPress.cancel(); off() }
    el.addEventListener('pointermove', longPress.move)
    el.addEventListener('pointerup', up)
    el.addEventListener('pointercancel', cancel)
  }
  return { longPress, onPress }
}

/** Run one action of a folded line (its menu entry or its Shift key). */
function flowLineRunner(o: FlowLineMenuOptions, aiList: ReturnType<typeof useAiListRun>, aiError: Ref<string>) {
  const { flow, lineSummary, openLine } = o
  const localePath = useLocalePath()
  return async function runLine(line: FlowLine, id: string) {
    if (id === 'open') return openLine(line, 'message')
    if (id === 'issue') return openLine(line, 'issue')
    if (id === 'release') return openLine(line, 'release')
    if (id === 'read') return flow.markOpened(line.key)
    if (id === 'copy') {
      const target = flowLineTarget(line)
      const path = target.to === 'release' ? target.path : line.link
      return void writeClipboard(window.location.origin + localePath(path))
    }
    if (id === 'copy-text') return void writeClipboard(lineSummary(line) + (line.title && line.text ? '\n' + line.text : ''))
    if (id.startsWith('ai-') && line.task_id) {
      flow.markOpened(line.key)
      aiError.value = await aiList.runTopic(id, line.task_id)
    }
  }
}

export function useFlowLineMenu(o: FlowLineMenuOptions) {
  const { flow, listEl, stack, isLine, openKey } = o
  const menu = reactive<MenuState>({ row: null, x: 0, y: 0 })
  const { menuLine, menuItems, menuAi } = flowMenuView(menu, isLine)
  const aiList = useAiListRun()
  const aiError = ref('')
  const runLine = flowLineRunner(o, aiList, aiError)
  const shortcutsOn = useMsgShortcutsOn()
  const shortcutsHelp = useMsgShortcutsHelp()
  function entryOf(key: string): FlowRow | null {
    return flow.visible.find((r: FlowRow) => r.key === key) || null
  }
  function openMenuAt(row: FlowRow, x: number, y: number) {
    flow.select(row.key)
    aiError.value = ''
    menu.row = row
    menu.x = x
    menu.y = y
  }
  function onMenu(key: string, ev: MouseEvent) {
    const row = entryOf(key)
    if (!row) return
    ev.preventDefault()
    openMenuAt(row, ev.clientX, ev.clientY)
  }
  const { longPress, onPress } = useRowLongPress(entryOf, openMenuAt)
  function menuAtRow(row: FlowRow) {
    const r = listEl.value?.rowEl(row.key)?.getBoundingClientRect()
    openMenuAt(row, r ? r.left + 16 : 16, r ? r.top + 24 : 16)
  }
  function onKey(ev: KeyboardEvent, key: string) {
    const row = entryOf(key)
    if (!row) return
    if (ev.key === 'ContextMenu' || (ev.key === 'F10' && ev.shiftKey)) {
      ev.preventDefault()
      return menuAtRow(row)
    }
    /* spec 130, owner t1 1cde1dd4 (f9300a98): the message keys on the selected
       line, each the menu entry of the same meaning (FLOW_LINE_ACTIONS) */
    if (!isLine(row)) return
    const sc = flowShortcutFor(ev, { enabled: shortcutsOn.value, phone: stack.isMobile.value })
    if (!sc) return
    ev.preventDefault()
    if (sc.type === 'help') {
      shortcutsHelp.value = true
      return
    }
    if (sc.key === 'R') return menuAtRow(row)
    const id = flowShortcutItem(sc.key, flowLineOffered(row))
    if (id) void runLine(row, id)
  }

  async function onMenuChoose(id: string) {
    const row = menu.row
    menu.row = null
    if (!row) return
    if (isLine(row)) return runLine(row, id)
    if (id === 'original') return void openKey(row.key)
    if (id.startsWith('ai-')) {
      flow.markOpened(row.key)
      aiError.value = await aiList.run(id, row)
    }
  }

  return { menu, menuLine, menuItems, menuAi, aiError, entryOf, longPress, onMenu, onPress, onKey, onMenuChoose }
}
