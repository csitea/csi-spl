/*
 * The doc view's section (item) point menu (r19-03, out of WorkspaceDocView):
 * the entries a section offers, in the owner's order, and what each one does:
 * the view-only entries here, the structural ones through the hub.
 */
import { computed, nextTick, type ComputedRef, type Ref } from 'vue'
import type { PointMenuItem } from '~/components/UiPointMenu.vue'
import {
  docMenuItems, runDocOp, moveTarget, setDocNumbered,
  type DocItem, type DocMenuId, type DocSession, type DocShape,
} from '~/components/workspace-docs/-doctree-api'
import { isNumbered } from '~/components/workspace-docs/-doc-outline'

type Translate = (key: string, named?: Record<string, unknown>) => string
type Figs = Map<string, { first: number, image: number }>

type ItemMenuView = {
  props: { session: DocSession, title: string }
  onList: (outline: string) => void
  onPrint: (it: DocItem) => void
  menu: Ref<{ x: number, y: number, item: DocItem } | null>
  doomed: Ref<DocItem | null>
  busy: Ref<boolean>
  /* Qto's "open as doc": one branch shown alone ('' = the whole document) */
  branch: Ref<string>
  rootEl: Ref<HTMLElement | null>
  byId: ComputedRef<Map<string, DocItem>>
  byParent: ComputedRef<Map<string, DocItem[]>>
  figs: ComputedRef<Figs>
  attr: (it: DocItem, k: string) => string
  paraShown: (it: DocItem) => boolean
  codeOpen: Set<string>
  openField: (it: DocItem, code: boolean) => Promise<void>
  pickImage: (it: DocItem) => void
  copyLink: (it: DocItem) => Promise<void>
  load: () => Promise<boolean>
  branchOf: (it: DocItem) => DocItem[]
  editTitle: (id: string) => Promise<void>
}

/** the section's entries, in the owner's order (msg dd291fb8): add paragraph, promote, demote, delete, and so on */
function menuList(it: DocItem, sh: DocShape, has: { para: boolean, code: boolean, image: boolean }): PointMenuItem[] {
  const can = (k: 'indent' | 'outdent' | 'up' | 'down') => Boolean(moveTarget(k, it, sh.prev, sh.parent, sh.count))
  const ops = new Map(docMenuItems({ indent: can('indent'), outdent: can('outdent'), up: can('up'), down: can('down') }).map((m) => [m.id, m]))
  const more: PointMenuItem[] = [
    { id: 'add_paragraph', icon: 'pencil', labelKey: 'ws_doctree.menu.add_paragraph' },
    { id: 'add_code', icon: 'file-code', labelKey: 'ws_doctree.menu.add_code' },
    { id: 'add_image', icon: 'file-image', labelKey: has.image ? 'ws_doctree.menu.replace_image' : 'ws_doctree.menu.add_image' },
    /* spec 137 T019 gap: the heading's Numbered switch, attrs.numbered (T012a) */
    { id: 'numbered', icon: 'hash', labelKey: isNumbered(it) ? 'ws_doctree.menu.numbering_off' : 'ws_doctree.menu.numbering_on' },
    /* spec 138 G2: the section's link, the stable id (owner msg 748ecf3c) */
    { id: 'copy_link', icon: 'copy', labelKey: 'ws_doctree.menu.copy_link' },
    { id: 'open_branch', icon: 'book-open', labelKey: 'ws_doctree.menu.open_branch' },
    { id: 'open_list', icon: 'file-spreadsheet', labelKey: 'ws_doctree.menu.open_list' },
    { id: 'export_md', icon: 'file-code', labelKey: 'ws_doctree.menu.export_md' },
    { id: 'export_csv', icon: 'file', labelKey: 'ws_doctree.menu.export_csv' },
  ]
  for (const m of more) ops.set(m.id, m)
  const order = ['add_paragraph', 'add_code', 'add_image', 'outdent', 'indent', 'delete', 'add_sibling', 'add_child', 'add_parent', 'up', 'down', 'numbered',
    'copy_link', 'open_branch', 'open_list', 'export_md', 'export_csv', 'print']
  return order.filter((id) => (id !== 'add_paragraph' || !has.para) && (id !== 'add_code' || !has.code)).map((id) => ops.get(id)).filter((m): m is PointMenuItem => Boolean(m))
}

/** the branch saved as Markdown or CSV: `name` is the document's title, `doc` its id (the figures' asset paths) */
async function exportBranch(md: boolean, it: DocItem, x: { part: DocItem[], name: string, doc: string, figs: Figs, t: Translate }) {
  const ex = await import('~/components/workspace-docs/-doctree-export')
  const t = x.t
  if (md) {
    const figure = (n: number) => t('ws_doctree.figure', { n })
    ex.saveText(ex.exportName(x.name, it.outline || it.title, 'md'), ex.branchToMarkdown(x.part, t('ws_doctree.untitled'), { doc: x.doc, figs: x.figs, figure }), 'text/markdown;charset=utf-8')
  }
  else ex.saveText(ex.exportName(x.name, it.outline || it.title, 'csv'), ex.branchToCsv(x.part, [t('ws_doctree.col_outline'), t('ws_doctree.col_level'), t('ws_doctree.col_title'), t('ws_doctree.col_body')]), 'text/csv;charset=utf-8')
}

/** the menu's view-only entries: open the branch alone or as a list, export it */
async function viewOp(v: ItemMenuView, t: Translate, id: string, it: DocItem): Promise<boolean> {
  const { props, busy } = v
  if (id === 'add_paragraph' || id === 'add_code') {
    await v.openField(it, id === 'add_code')
    return true
  }
  if (id === 'numbered') {
    /* the hub re-numbers the siblings after it (and everything under them): read the document again */
    busy.value = true
    try {
      if (await setDocNumbered(props.session, it, !isNumbered(it))) await v.load()
    } finally {
      busy.value = false
    }
    return true
  }
  if (id === 'copy_link') {
    await v.copyLink(it)
    return true
  }
  if (id === 'add_image') {
    v.pickImage(it)
    return true
  }
  if (id === 'open_branch') {
    v.branch.value = it.id
    await nextTick()
    v.rootEl.value?.scrollIntoView({ block: 'start' })
    return true
  }
  if (id === 'open_list') {
    v.onList(it.outline)
    return true
  }
  if (id !== 'export_md' && id !== 'export_csv') return false
  const name = props.title || t('ws_doctree.default_doc_title')
  await exportBranch(id === 'export_md', it, { part: v.branchOf(it), name, doc: props.session.doc, figs: v.figs.value, t })
  return true
}

export function useDocItemMenu(v: ItemMenuView) {
  const { t } = useI18n({ useScope: 'global' })
  const { props, menu, busy } = v

  function shapeOf(it: DocItem): DocShape {
    const sib = v.byParent.value.get(it.parent) ?? []
    const i = sib.findIndex((s) => s.id === it.id)
    return { prev: i > 0 ? sib[i - 1] : undefined, parent: v.byId.value.get(it.parent), count: sib.length }
  }

  const menuItems = computed(() => {
    const it = menu.value?.item
    if (!it) return []
    const code = Boolean(v.attr(it, 'src')) || v.codeOpen.has(it.id)
    return menuList(it, shapeOf(it), { para: v.paraShown(it), code, image: Boolean(v.attr(it, 'img_http_path')) })
  })

  function openMenu(item: DocItem, x: number, y: number) {
    menu.value = { x, y, item }
  }
  function openMenuAt(item: DocItem, e: MouseEvent) {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect()
    openMenu(item, r.left, r.bottom)
  }

  async function choose(id: string) {
    const it = menu.value?.item
    menu.value = null
    if (!it) return
    if (await viewOp(v, t, id, it)) return
    const op = id as DocMenuId
    if (op === 'print') return v.onPrint(it)
    if (op === 'delete') {
      v.doomed.value = it
      return
    }
    busy.value = true
    try {
      const r = await runDocOp(props.session, op, it, shapeOf(it), t('ws_doctree.untitled'))
      if (!r) return
      await v.load()
      if (r.item) await v.editTitle(r.item)
    } finally {
      busy.value = false
    }
  }

  return { menuItems, openMenu, openMenuAt, choose }
}
