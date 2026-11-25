import { inject, provide, type InjectionKey } from 'vue'

/**
 * SPL-6480: is this component rendered inside a UiDialog?
 *
 * A point menu is teleported to <body> at --z-overlay, under --z-modal, so a
 * message card inside a modal (an issue's comment, HUM-24 csitea 5c9dcfe7)
 * opened its menu BEHIND the dialog: the items were in the DOM, nothing could
 * be clicked. UiDialog provides the flag, MessageMenu reads it and lifts its
 * panel over the modal (UiPointMenu's over-modal). Outside any dialog it is
 * false.
 */
const IN_MODAL: InjectionKey<boolean> = Symbol('in-modal')

/** UiDialog: everything in its slots is inside a modal. */
export function provideInModal() {
  provide(IN_MODAL, true)
}

/** A popover host: true when a UiDialog is above it in the component tree. */
export function useInModal(): boolean {
  return inject(IN_MODAL, false)
}
