/*
 * CLE-77888 (owner, t1 topic 1701ae89): the phone's ~5 mm status strip at the
 * very bottom (components/MobileStatusStrip.vue). Its height (0 while it is
 * not shown) is shared here and mirrored to `--status-strip-h` on <html>, so
 * the docked composer sits on top of it and reports both as its dock height
 * (`--composer-dock-h`): the panes, the snackbars and the send error, which
 * already clear that, clear the strip too.
 */
const stripH = ref(0)

export function setStatusStripHeight(px: number) {
  const h = Math.max(0, Math.round(px))
  stripH.value = h
  if (typeof document === 'undefined') return
  const root = document.documentElement
  root.style.setProperty('--status-strip-h', `${h}px`)
  if (h > 0) root.setAttribute('data-status-strip', '')
  else root.removeAttribute('data-status-strip')
}

export function useStatusStripHeight() {
  return stripH
}
