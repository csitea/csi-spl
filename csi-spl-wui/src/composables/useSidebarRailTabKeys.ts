/*
 * ChannelSidebar's rail-tab keys (r16-06, spec 103 T006): Enter on a rail
 * tab opens its section and goes into its list; the arrows, Home and End
 * walk the tabs.
 */
import type { Ref } from 'vue'
import { useSessionStore } from '~/stores/session'

/* spec 103 T006 (t1 7d9e1681): the vim ring (vim-nav.css) on the row the
   keys moved to, the one ring on screen (useVimNavigation marks it alike) */
function vimRing(el: HTMLElement) {
  for (const old of document.querySelectorAll<HTMLElement>('[data-vim-selected]')) if (old !== el) old.removeAttribute('data-vim-selected')
  el.setAttribute('data-vim-selected', 'true')
  el.focus({ preventScroll: true })
}

export function useSidebarRailTabKeys<T extends string>(opts: {
  phone: Ref<boolean>
  tab: Ref<T>
  rail: Ref<ReadonlyArray<{ id: T }>>
  railClick: (id: T) => Promise<unknown>
  selectTab: (id: T) => Promise<unknown>
}) {
  const { phone, tab, rail, railClick, selectTab } = opts
  const session = useSessionStore()
  /* spec 103 T006: Enter on a rail tab (j / k walk the tabs without opening
     them) opens that section and puts the focus in its list, Panel 1: the open
     channel or DM, else the first row. A section with no list here (Issues,
     Calendar, ...) keeps what its page does with the focus. */
  async function enterRailTab(id: T) {
    await railClick(id)
    await nextTick()
    const panel = document.getElementById('sidebar-panel-' + id)
    if (!panel || panel.getClientRects().length === 0) return
    const rows = [...panel.querySelectorAll<HTMLElement>('.nav-item')].filter((el) => el.getClientRects().length > 0)
    const to = rows.find((el) => el.matches('.active, [aria-current="page"]')) || rows.find((el) => el.matches('a[href]')) || rows[0]
    if (to) vimRing(to)
  }
  function onTabKey(e: KeyboardEvent) {
    if (e.key === 'Enter' && !e.shiftKey && !e.ctrlKey && !e.metaKey && !e.altKey && !phone.value && session.claims?.keyboard_shortcuts !== false) {
      const id = (e.currentTarget as HTMLElement | null)?.dataset.reorderId as T | undefined
      if (!id) return
      e.preventDefault()
      void enterRailTab(id)
      return
    }
    const order = rail.value.map((item) => item.id)
    const i = order.indexOf(tab.value)
    let n = -1
    if (e.key === 'ArrowDown') n = (i + 1) % order.length
    else if (e.key === 'ArrowUp') n = (i - 1 + order.length) % order.length
    else if (e.key === 'Home') n = 0
    else if (e.key === 'End') n = order.length - 1
    else return
    e.preventDefault()
    const next = order[n]
    void selectTab(next)
    document.getElementById('sidebar-tab-' + next)?.focus()
  }
  return { onTabKey }
}
