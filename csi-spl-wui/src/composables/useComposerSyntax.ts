// r13-03: the top-bar box's "?" (on the phone dock: the Search button) and
// its operator panel, moved out of MessageComposer.vue.
import type { Ref } from 'vue'
import { omniboxMode, omniboxTextLeavingSearch } from '~/utils/search.mjs'
import type { ComposerProps } from '~/composables/composerProps'

interface SyntaxOpts {
  text: Ref<string>
  inputEl: Ref<HTMLTextAreaElement | null>
  caretAt: Ref<number>
  docked: Ref<boolean>
  searchMode: Ref<boolean>
  props: ComposerProps
  setText: (s: string) => void
  focusInput: () => void
  /** the template's "?" button and the field around it */
  syntaxBtn: Ref<HTMLButtonElement | null>
  fieldEl: Ref<HTMLElement | null>
}

/* t1 e142d4a0 (owner HUM-10): search starts only on a press that lands
   inside the drawn button's square and is let go there, judged by the
   pointer's own points, never by which element Chrome sends the click to.
   Its touch adjustment moves a tap next to the button onto it (390 px: taps
   at x 189..196 hit the button, which starts at 197) and a tap on the
   square's edge off it; and the click the browser fires after the keyboard
   moved the dock has no press on the button at all. So the pointer path
   runs on pointerup, the click that follows is dropped, and any other click
   on the button only focuses the box. A keyboard click (detail 0 on the
   focused button) still works. */
function useSyntaxPress(o: SyntaxOpts, syntaxOpen: Ref<boolean>, run: () => void) {
  const { syntaxBtn, fieldEl } = o
  let syntaxPress = 0
  let syntaxRan = 0
  function pressInSyntaxSquare(ev: PointerEvent): boolean {
    const r = syntaxBtn.value?.getBoundingClientRect()
    return Boolean(ev.button === 0 && r && r.width && ev.clientX >= r.left && ev.clientX <= r.right && ev.clientY >= r.top && ev.clientY <= r.bottom)
  }
  function forgetSyntaxPress() { syntaxPress = 0 }
  function onSyntaxPointerUp(ev: PointerEvent) {
    const pressed = syntaxPress > 0 && pressInSyntaxSquare(ev)
    forgetSyntaxPress()
    if (!pressed) return
    syntaxRan = ev.timeStamp
    run()
  }
  function onSyntaxClick(ev: MouseEvent) {
    if (ev.detail === 0 && document.activeElement === ev.currentTarget) return run()
    const ran = syntaxRan > 0 && ev.timeStamp - syntaxRan < 1500
    syntaxRan = 0
    if (!ran) o.focusInput()
  }
  function onSyntaxPointerDown(ev: PointerEvent) {
    syntaxPress = pressInSyntaxSquare(ev) ? ev.timeStamp : 0
    if (!syntaxOpen.value) return
    const root = fieldEl.value
    if (root && ev.target instanceof Node && root.contains(ev.target)) return
    syntaxOpen.value = false
  }
  onMounted(() => {
    if (!o.props.global) return
    window.addEventListener('pointerdown', onSyntaxPointerDown)
    window.addEventListener('pointerup', onSyntaxPointerUp)
    window.addEventListener('pointercancel', forgetSyntaxPress)
  })
  onBeforeUnmount(() => {
    window.removeEventListener('pointerdown', onSyntaxPointerDown)
    window.removeEventListener('pointerup', onSyntaxPointerUp)
    window.removeEventListener('pointercancel', forgetSyntaxPress)
  })
  return { onSyntaxClick }
}

export function useComposerSyntax(o: SyntaxOpts) {
  const syntaxOpen = ref(false)
  const syntaxId = useId()
  function insertOperator(op: string) {
    syntaxOpen.value = false
    const cur = o.text.value
    const next = omniboxMode(cur) !== 'search'
      ? `/search ${op}`
      : (() => {
          const at = o.inputEl.value?.selectionStart ?? cur.length
          const gap = at > 0 && !/\s/.test(cur[at - 1] || '') ? ' ' : ''
          return cur.slice(0, at) + gap + op + cur.slice(at)
        })()
    o.text.value = next
    nextTick(() => {
      const el = o.inputEl.value
      if (!el) return
      o.caretAt.value = next.length
      el.focus()
      el.setSelectionRange(next.length, next.length)
    })
  }
  /* 085 FR-004: the phone Search button. Search mode is the state `/search `
     sets, so a typed line that was there becomes the query; a second tap clears
     the search line (omniboxTextLeavingSearch) and closes the list */
  function onSyntaxButton() {
    if (!o.docked.value) {
      syntaxOpen.value = !syntaxOpen.value
      return
    }
    if (o.searchMode.value) {
      syntaxOpen.value = false
      o.setText(omniboxTextLeavingSearch(o.text.value))
      return
    }
    o.setText(o.text.value.trim() ? `/search ${o.text.value.trim()}` : '/search ')
    o.focusInput()
    /* after the text watcher, which closes the list on every edit - and so
       closes it again once the box is emptied (search mode left) */
    void nextTick(() => { syntaxOpen.value = true })
  }
  return { syntaxOpen, syntaxId, insertOperator, ...useSyntaxPress(o, syntaxOpen, onSyntaxButton) }
}
