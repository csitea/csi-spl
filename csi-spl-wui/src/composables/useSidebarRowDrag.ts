/*
 * ChannelSidebar's row drag (r13-04): a Direct messages or Channels row held
 * and moved re-orders its list; the click that ends a drag opens nothing.
 */
import { ref, type Ref } from 'vue'
import { dropIndex, moveKey } from '~/utils/sidebar-row-menu.mjs'

export function useSidebarRowDrag(pinnedPeers: Ref<string[]>, channelOrder: Ref<string[]>, setChannelOrder: (next: string[]) => unknown) {
  type DragList = 'peers' | 'channels'
  const drag = ref<{ list: DragList, key: string, overIndex: number, active: boolean } | null>(null)
  let suppressDragClick = false
  const dragPanel: Record<DragList, string> = {
    peers: 'sidebar-panel-dm',
    channels: 'sidebar-panel-channels',
  }
  function orderBag(list: DragList) {
    if (list === 'peers') return pinnedPeers
    return channelOrder
  }
  function dragging(list: DragList, key: string) {
    const d = drag.value
    return !!d && d.active && d.list === list && d.key === key
  }
  function dropping(list: DragList, key: string, index: number) {
    const d = drag.value
    if (!d || !d.active || d.list !== list || d.key === key) return false
    if (d.overIndex === index) return true
    return false
  }
  function droppingAfter(list: DragList, index: number, last: number) {
    const d = drag.value
    return !!d && d.active && d.list === list && d.overIndex >= last && index === last - 1
  }
  function rowPointerDown(e: PointerEvent, list: DragList, key: string) {
    if (e.button !== 0) return
    const target = e.target
    if (!(target instanceof Element) || target.closest('.sidebar-row-menu, button, input, textarea')) return
    const startY = e.clientY
    const pointerId = e.pointerId
    let active = false
    let overIndex = 0
    const panelId = dragPanel[list]
    const keysNow = () => {
      const panel = document.getElementById(panelId)
      return panel ? [...panel.querySelectorAll<HTMLElement>('.nav-row')].map((el) => el.dataset.order || '') : []
    }
    const move = (ev: PointerEvent) => {
      if (ev.pointerId !== pointerId) return
      if (!active && Math.abs(ev.clientY - startY) < 6) return
      active = true
      const panel = document.getElementById(panelId)
      const els = panel ? [...panel.querySelectorAll<HTMLElement>('.nav-row')] : []
      const rects = els.map((el) => {
        const r = el.getBoundingClientRect()
        return { top: r.top, bottom: r.bottom }
      })
      overIndex = dropIndex(rects, ev.clientY)
      drag.value = { list, key, overIndex, active: true }
    }
    const up = () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      if (active) {
        suppressDragClick = true
        const keys = keysNow()
        const from = keys.indexOf(key)
        if (from >= 0) {
          const next = moveKey(keys, from, overIndex)
          if (list === 'channels') void setChannelOrder(next)
          else orderBag(list).value = next
        }
      }
      drag.value = null
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }
  function swallowDragClick(e: MouseEvent) {
    if (!suppressDragClick) return
    suppressDragClick = false
    e.preventDefault()
    e.stopPropagation()
  }
  return { dragging, dropping, droppingAfter, rowPointerDown, swallowDragClick }
}
