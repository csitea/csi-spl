// omnibox-call.ts - put the caret in a composer AND show the reader where it
// went (SPL-4696).
//
// SPL-2699 (owner, t1 b4f175c7) found it on an empty DM: "the caret alone in a
// box ... read as 'nothing happened'". The same held for the empty channel's
// "Write the first message" and for every Reply that sends the caret to the
// composer (csitea 597318eb, a member: the channel looked empty and "when I
// click to open a discussion, it does not open"; owner HUM-10 msg 1bfcbc43:
// "some effect or animation that shows the user to start typing and where the
// focus is"). The focus ring is a 1px hairline by earlier owner orders
// (main.css, the omnibox focus ring), so the call itself is marked: the box
// scrolls into view and its form carries .omnibox--called for
// OMNIBOX_CALLED_MS (a pulse; a steady ring under reduced motion, main.css).
// Nothing else changes: the same element gets the focus.

/** The composer the Omnibox is (TopBar.vue). */
export const OMNIBOX_TEXTAREA = 'form.omnibox--global textarea'
const OMNIBOX_CALLED = 'omnibox--called'
const OMNIBOX_CALLED_MS = 2400

const timers = new WeakMap<Element, ReturnType<typeof setTimeout>>()

/** Focus `box`, bring its form into view and mark it; false: no box. */
export function callOmnibox(box: HTMLTextAreaElement | null | undefined): boolean {
  if (!box) return false
  const form = box.closest('form')
  form?.scrollIntoView({ block: 'nearest' })
  box.focus()
  if (!form) return true
  /* a second call restarts the pulse: drop the class, flush, add it again */
  form.classList.remove(OMNIBOX_CALLED)
  void form.offsetWidth
  form.classList.add(OMNIBOX_CALLED)
  clearTimeout(timers.get(form))
  timers.set(form, setTimeout(() => form.classList.remove(OMNIBOX_CALLED), OMNIBOX_CALLED_MS))
  return true
}
