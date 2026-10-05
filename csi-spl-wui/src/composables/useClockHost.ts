/*
 * Owner, t1 be316fdc: the last-updated clock (LastDataClock) sits right of
 * the version - the sidebar footer's on a desktop, the status strip's on a
 * phone. A screen that draws neither (a rail-only or hidden sidebar, a sheet
 * over the phone strip) keeps it in the top bar's corner, so every screen
 * shows exactly one clock. Each host says whether its version is on screen;
 * the top bar mounts the clock only while neither is.
 */
const foot = ref(false)
const strip = ref(false)
const bar = computed(() => !foot.value && !strip.value)

export function useClockHost() {
  return { foot, strip, bar }
}
