/* Close a phone's bottom sheet (components/SheetPhoneBar.vue) as a person
   does: a tap on the scrim ABOVE the sheet, where the scrim shows.

   page.click() on the scrim aims at its centre. The scrim covers the whole
   viewport and the sheet sits over its lower 75 %, so with many columns (Lanes
   has 12) the centre is inside the sheet: the "close" pressed a sort row
   (Prio) instead (SPL-5276; elementFromPoint at the centre at 320x844 and
   390x844 -> lanes-sort-priority). This taps half way between the scrim's top
   and the sheet's top, then waits the sheet's Back step out (the Event log's
   tests wait the same 400 ms). */
export async function tapScrim(p, prefix) {
  const at = await p.evaluate((pre) => {
    const scrim = document.querySelector(`[data-test=${pre}-sheet-scrim]`)
    if (!scrim) return null
    const s = scrim.getBoundingClientRect()
    const sheet = document.querySelector(`[data-test=${pre}-sort-sheet], [data-test=${pre}-filters]`)
    const top = sheet ? sheet.getBoundingClientRect().top : s.bottom
    const x = s.left + s.width / 2
    const y = s.top + (top - s.top) / 2
    const hit = document.elementFromPoint(x, y)
    return { x, y, onScrim: hit === scrim }
  }, prefix)
  if (!at) return false
  if (!at.onScrim) throw new Error(`tapScrim ${prefix}: no visible scrim above the sheet at ${Math.round(at.x)},${Math.round(at.y)}`)
  await p.mouse.click(at.x, at.y)
  await new Promise((r) => setTimeout(r, 400))
  return true
}
