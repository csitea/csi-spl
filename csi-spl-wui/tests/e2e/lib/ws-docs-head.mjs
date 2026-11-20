// SPL-6083 (owner HUM-10, t1 60bf4e56, msgs ce88082a and 55440858): with a
// Qto document open the page header has no document picker, no Documents
// label, no + and no Outline / Grid pills. The e2e tests reach the same
// actions the way a user now does:
//   newDocDialog(p)  the + where the page still draws it (a phone's list, no
//                    document yet), else the explorer tree's / row menu,
//                    New document (QtoFileTree; it makes the document at the
//                    top level)
//   setDocView(p, v) the header's file menu, Outline ('doc') or Grid ('grid')
//   openDocId(p)     the open document's id: ?doc=, else the tree's active row
//   pickDoc(p, id)   a click on the document's row in the explorer tree
const STEP = 15000

async function shown(p, sel) {
  return p.$eval(sel, (el) => el.getBoundingClientRect().width > 0).catch(() => false)
}

/** opens the new-document modal; resolves once its title field is shown */
export async function newDocDialog(p, { timeout = STEP } = {}) {
  if (await shown(p, '[data-test=ws-docs-new]')) {
    await p.click('[data-test=ws-docs-new]')
  } else {
    const at = await p.waitForFunction(() => {
      const el = document.querySelector('#qto-file-tree [data-test=file-tree-row][data-key="/"]')
      if (!el) return null
      const r = el.getBoundingClientRect()
      return r.width > 0 ? { x: r.left + 40, y: r.top + r.height / 2 } : null
    }, { timeout }).then((h) => h.jsonValue())
    await p.mouse.click(at.x, at.y, { button: 'right' })
    await p.waitForSelector('[data-testid=qto-root-menu-new_doc]', { visible: true, timeout })
    await p.click('[data-testid=qto-root-menu-new_doc]')
  }
  await p.waitForSelector('[data-test=ws-docs-new-title]', { visible: true, timeout })
}

/** Outline ('doc') or Grid ('grid') from the header's file menu; resolves once that view is shown */
export async function setDocView(p, v, { timeout = STEP } = {}) {
  await p.waitForSelector('[data-test=ws-doc-file-btn]', { visible: true, timeout })
  await p.click('[data-test=ws-doc-file-btn]')
  await p.waitForSelector(`[data-test=ws-doc-file-menu-view_${v}]`, { visible: true, timeout })
  await p.click(`[data-test=ws-doc-file-menu-view_${v}]`)
  await p.waitForSelector(`[data-test=ws-${v}-view]`, { visible: true, timeout })
}

/** the open document's id ('' = none) */
export function openDocId(p) {
  return p.evaluate(() => new URL(location.href).searchParams.get('doc')
    || (document.querySelector('#qto-file-tree [data-test=file-tree-row][aria-selected=true]')?.getAttribute('data-key') ?? '').replace(/^d:/, ''))
}

/** opens a document from its explorer tree row; resolves once ?doc= names it */
export async function pickDoc(p, id, { timeout = STEP } = {}) {
  await p.click(`#qto-file-tree [data-test=file-tree-row][data-key="d:${id}"]`)
  await p.waitForFunction((id) => new URL(location.href).searchParams.get('doc') === id, { timeout }, id)
}
