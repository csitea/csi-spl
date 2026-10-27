/**
 * The sort a sheet header click cycles through, shared by the Issues list
 * (issues-view.mjs nextSort) and Monitoring -> Lanes (SPL-3887; owner
 * HUM-10, t1 31f6f470, msgs 1eedefed and 08b25696: "the lanes listing ...
 * must be sortable and filterable", the same controls as the issues
 * listing). The button that shows it is components/SheetSortButton.vue.
 */

/**
 * A header click: none -> ascending -> descending -> back to the default
 * ('' = the list's own order). A column not in `columns` is the default.
 * @param {string} col
 * @param {{ col: string, dir: string }} cur
 * @param {readonly string[]} columns
 * @returns {{ col: string, dir: '' | 'asc' | 'desc' }}
 */
export function cycleSort(col, cur, columns) {
  if (!columns.includes(col)) return { col: '', dir: '' }
  if (cur.col !== col) return { col, dir: 'asc' }
  if (cur.dir === 'asc') return { col, dir: 'desc' }
  return { col: '', dir: '' }
}
