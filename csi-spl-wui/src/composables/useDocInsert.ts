/*
 * The doc view's paragraph editor (r14-01, out of WorkspaceDocView): a
 * textarea as tall as its text, a paragraph or code block opened from the
 * menu, a read paragraph opened for editing, and Insert table / Insert quote
 * (spec 137 T010, T011) at its cursor.
 */
import { nextTick, reactive, type Ref } from 'vue'
import { insertBlock, quoteBlock, tableBlock, type Block } from '~/components/workspace-docs/-doc-blocks'
import type { DocItem } from '~/components/workspace-docs/-doctree-api'
import { useEditModeStore } from '~/stores/editMode'

/* a textarea as tall as its text; field-sizing: content does it where the browser has it */
const fieldSizing = typeof CSS !== 'undefined' && CSS.supports?.('field-sizing', 'content')

export function useDocInsert(rootEl: Ref<HTMLElement | null>) {
  const { t } = useI18n({ useScope: 'global' })
  const editMode = useEditModeStore()
  /* the level-1 sections whose (empty) paragraph the user opened */
  const paraOpen = reactive(new Set<string>())
  /* the sections whose (empty) code block the user opened from the menu */
  const codeOpen = reactive(new Set<string>())
  /* the read paragraphs opened for editing */
  const paraEditing = reactive(new Set<string>())

  function grow(el: HTMLTextAreaElement) {
    if (fieldSizing) return
    el.style.height = 'auto'
    el.style.height = el.scrollHeight + 'px'
  }
  function growAll() {
    if (fieldSizing) return
    rootEl.value?.querySelectorAll<HTMLTextAreaElement>('.wsdoc__item textarea').forEach(grow)
  }

  /** Esc: the field's text as it was, the field left */
  function revert(el: HTMLTextAreaElement, was: string) {
    el.value = was
    grow(el)
    el.blur()
    editMode.setEditing(false)
  }

  /** a section's paragraph textarea (its code block's with `code`) */
  function textOf(id: string, code = false) {
    return rootEl.value?.querySelector<HTMLTextAreaElement>(`[data-id="${id}"] [data-test=ws-doc-${code ? 'src' : 'text'}]`) ?? null
  }

  /** the menu's Add paragraph / Add code: the empty field shown and focused */
  async function openField(it: DocItem, code: boolean) {
    const opened = code ? codeOpen : paraOpen
    opened.add(it.id)
    await nextTick()
    textOf(it.id, code)?.focus()
  }

  /** a read paragraph opened for editing, its cursor at the end */
  async function editPara(id: string) {
    paraEditing.add(id)
    await nextTick()
    const el = textOf(id)
    if (!el) return
    grow(el)
    el.focus()
    el.setSelectionRange(el.value.length, el.value.length)
  }

  /** the block goes into the paragraph being edited, at the cursor, and its
      first placeholder is selected; the paragraph saves when it is left, as
      typed text does */
  function insertAt(it: DocItem, make: (selected: string) => Block) {
    const el = textOf(it.id)
    if (!el) return
    const r = insertBlock(el.value, el.selectionStart, el.selectionEnd, make)
    el.value = r.value
    grow(el)
    el.focus()
    el.setSelectionRange(r.selStart, r.selEnd)
  }
  function insertTable(it: DocItem) {
    insertAt(it, () => tableBlock((n) => t('ws_doctree.table_header', { n }), (n) => t('ws_doctree.table_cell', { n })))
  }
  function insertQuote(it: DocItem) {
    insertAt(it, (selected) => quoteBlock(selected, t('ws_doctree.quote_text'), t('ws_doctree.quote_source')))
  }

  return { fieldSizing, paraOpen, codeOpen, paraEditing, grow, growAll, textOf, revert, editPara, openField, insertTable, insertQuote }
}
