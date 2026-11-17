// csi-spl-wui/src/utils/view-prefs-core.mjs
//
// SPL-5780: the one view preference the first screen reads. app.vue stamps
// `data-close-buttons` on <html> from the close_buttons claim, and that was
// its only use of view-prefs.mjs, which kept the whole file (the other lists,
// displayOrder, applyViewPref) in the initial chunk. view-prefs.mjs takes its
// CLOSE_BUTTONS list from here, so the two never disagree, and its
// parseCloseButtons answers what closeButtonsOf answers
// (tests/unit/view-prefs.test.mjs). Own names: utils/ exports are
// auto-imported, and the same name in two files would collide.

/** close_buttons values, the owner's default ('mac', SPL-1133) first. */
export const CLOSE_BUTTON_STYLES = Object.freeze(['mac', 'windows'])

/** The close_buttons claim exactly, else its default. */
export function closeButtonsOf(raw) {
  return CLOSE_BUTTON_STYLES.includes(raw) ? raw : CLOSE_BUTTON_STYLES[0]
}
