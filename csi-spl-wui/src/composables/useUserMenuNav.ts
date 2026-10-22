/**
 * The user menu's WAI-ARIA menu button (r18-07, moved out of UserMenu.vue):
 * its open state, the focused item, the panel placement and the keys.
 * Enter/Space (click) and ArrowDown open on the first item, ArrowUp on the
 * last; nextMenuIndex moves inside the menu; Escape closes it and puts the
 * focus back on the button. Its one input is `phone`, the SFC's answer to
 * "is this the phone layout": there the panel is a bottom sheet placed by
 * CSS. The button and the nine items are bound by name (`ref="trigger"`,
 * `ref="item0"` etc. in the SFC's template) through useTemplateRef.
 */
import { useTemplateRef } from 'vue'
import type { Ref, ShallowRef } from 'vue'
import { nextMenuIndex } from '~/utils/user-menu'
import { applyPopover, focusWithoutScroll, readViewport } from '~/utils/place-popover'

/* drop the popover style but keep `display`. The panel is v-if now (SPL-2123),
   so a closed one is not in the DOM; the guard stays because, under v-show,
   wiping the whole style attribute on a rotation SHOWED the closed menu,
   which then sat over the page and took its clicks (c-155: a card's open
   icon opened Settings) */
function clearPopover(panel: HTMLElement | null | undefined) {
  if (!panel) return
  const display = panel.style.display
  panel.removeAttribute('style')
  if (display) panel.style.display = display
}

/* the nine items, bound by the SFC's ref="item0" etc. (useTemplateRef: the
   SFC needs no binding of its own for a ref only its template names) */
function itemRefs() {
  return {
    item0: useTemplateRef<{ $el: HTMLElement }>('item0'),
    item1: useTemplateRef<HTMLButtonElement>('item1'),
    itemTenant: useTemplateRef<{ $el: HTMLElement }>('itemTenant'),
    itemActAs: useTemplateRef<HTMLButtonElement>('itemActAs'),
    itemStatus: useTemplateRef<HTMLButtonElement>('itemStatus'),
    itemPassword: useTemplateRef<{ $el: HTMLElement }>('itemPassword'),
    itemActAsStop: useTemplateRef<HTMLButtonElement>('itemActAsStop'),
    itemPicture: useTemplateRef<HTMLButtonElement>('itemPicture'),
    itemPictureRemove: useTemplateRef<HTMLButtonElement>('itemPictureRemove'),
  }
}

/* the rendered items in menu order: a v-if'd item is skipped */
function menuItems(r: ReturnType<typeof itemRefs>): HTMLElement[] {
  return [r.item0.value?.$el, r.itemPicture.value, r.itemPictureRemove.value, r.itemPassword.value?.$el, r.itemStatus.value, r.itemTenant.value?.$el, r.itemActAs.value, r.itemActAsStop.value, r.item1.value].filter((el): el is HTMLElement => !!el)
}

function placePanel(root: Ref<HTMLElement | null>, trigger: Readonly<ShallowRef<HTMLButtonElement | null>>, phone: () => boolean) {
  const panel = root.value?.querySelector<HTMLElement>('.user-menu__panel')
  /* the bottom sheet is placed by CSS, not next to the button: a popover
     style left from a desktop open must not override it */
  if (phone()) { clearPopover(panel); return }
  const btn = trigger.value
  if (!panel || !btn) return
  const r = btn.getBoundingClientRect()
  applyPopover(panel, {
    left: r.left,
    right: r.right,
    top: r.top,
    bottom: r.bottom,
    align: 'end',
    gap: 6,
  }, readViewport())
}

export type UserMenuNavOptions = {
  phone: () => boolean
}

export function useUserMenuNav({ phone }: UserMenuNavOptions) {
  const open = ref(false)
  const focused = ref(-1)
  const root = ref<HTMLElement | null>(null)
  const trigger = useTemplateRef<HTMLButtonElement>('trigger')
  const refs = itemRefs()
  const items = () => menuItems(refs)

  /* i < 0 counts from the end (-1 = the last item). The panel is v-if: its
     items exist only after the render that opens it, so the index is resolved
     after nextTick, never from items() of a closed menu (SPL-2123) */
  async function focusItem(i: number) {
    focused.value = i
    await nextTick()
    if (i < 0) focused.value = i = Math.max(0, items().length + i)
    placePanel(root, trigger, phone)
    focusWithoutScroll(items()[i])
  }

  function openAt(i: number) {
    open.value = true
    void focusItem(i)
  }

  function close(refocus: boolean) {
    open.value = false
    focused.value = -1
    if (refocus) focusWithoutScroll(trigger.value)
  }

  function toggle() {
    if (open.value) close(false)
    else openAt(0)
  }

  function onTriggerKey(e: KeyboardEvent) {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      openAt(0)
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      openAt(-1)
    } else if (e.key === 'Escape' && open.value) {
      e.preventDefault()
      close(true)
    }
  }

  function onMenuKey(e: KeyboardEvent) {
    const n = items().length
    const next = nextMenuIndex(focused.value, e.key, n)
    if (next === -1) {
      // Tab moves on naturally; Escape returns to the button
      if (e.key === 'Escape') { e.preventDefault(); close(true) } else close(false)
      return
    }
    if (next !== focused.value) {
      e.preventDefault()
      void focusItem(next)
    }
  }

  return { open, root, clearPopover, close, toggle, onTriggerKey, onMenuKey }
}
