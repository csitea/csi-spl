<!-- A table in a post, sortable by a click on its column header (md-tables
     panel plan v1.0 section 3.2, SPL-2466 row 05; owner HUM-10, t1 8f983920:
     "Make all of the tables in the topics' msgs sortable").

     MarkdownBlock's MdNodes is functional, so the sort state lives here. Only
     a table utils/table-sort.ts sortModel accepts gets the buttons: a header
     row, >= 3 body rows, no colspan / rowspan, no no-sort hint. A click
     cycles ascending, descending, then the author's order (sheet-sort.mjs
     cycleSort, the Issues list's cycle); the th carries aria-sort. The sort
     is a view: the tree, Show source and the copied post keep the author's
     order. Every other node is drawn by MarkdownBlock (`render`), so a cell
     keeps its links, code and mentions. This component is a lazy chunk:
     MarkdownBlock loads it only for a post that holds a table. -->
<template>
  <Grid />
</template>

<script setup lang="ts">
import { h, type VNodeChild } from 'vue'
import type { MdNode } from '~/utils/markdown.mjs'
import { sortModel, sortOrder, cellText, type MdEl } from '~/utils/table-sort'
import { cycleSort } from '~/utils/sheet-sort.mjs'

const props = defineProps<{
  /* the table node of the markdown tree */
  node: MdEl
  /* its md-table--<hint> classes, filtered already */
  cls: string
  /* MarkdownBlock's own node renderer */
  render: (n: MdNode) => VNodeChild
}>()

const { t, locale } = useI18n({ useScope: 'global' })
const sort = ref<{ col: string, dir: string }>({ col: '', dir: '' })
const model = computed(() => sortModel(props.node))
/* a new tree (an edited post) starts in the author's order */
watch(() => props.node, () => { sort.value = { col: '', dir: '' } })

const columns = computed(() => (model.value ? model.value.head.children.filter((c) => typeof c !== 'string').map((_, j) => String(j)) : []))
const order = computed(() => {
  const m = model.value
  if (!m || !sort.value.col) return null
  const j = Number(sort.value.col)
  return sortOrder(m.cells.map((r) => r[j] ?? ''), sort.value.dir === 'desc' ? 'descending' : 'ascending', locale.value)
})

const isEl = (n: MdNode): n is MdEl => typeof n !== 'string'
const hasLink = (n: MdNode): boolean => isEl(n) && (n.tag === 'a' || n.children.some(hasLink))
const ariaSort = (j: number) => (sort.value.col !== String(j) ? 'none' : sort.value.dir === 'desc' ? 'descending' : 'ascending')

function onSort(e: Event, j: number) {
  e.stopPropagation()
  sort.value = cycleSort(String(j), sort.value, columns.value)
}
/* Enter / Space press the button; the card around the post must not see them */
function onKey(e: KeyboardEvent) {
  if (e.key === 'Enter' || e.key === ' ') e.stopPropagation()
}

function headCell(c: MdEl, j: number): VNodeChild {
  const attrs: Record<string, string> = {}
  if (c.attrs['data-align']) attrs['data-align'] = c.attrs['data-align']
  const kids = c.children.map((k) => props.render(k))
  /* a link in a header cell stays a link: a button must not hold one */
  if (hasLink(c)) return h(c.tag, attrs, kids)
  const state = ariaSort(j)
  const name = cellText(c) || String(j + 1)
  return h(c.tag, { ...attrs, 'aria-sort': state, 'data-test': 'md-th-sort' }, [h('button', {
    type: 'button',
    class: 'md-th-sort',
    'data-sorted': state === 'none' ? undefined : state,
    'aria-label': t('markdown.table_sort.sort_by', { column: name, state: t(`markdown.table_sort.state_${state}`) }),
    title: t('markdown.table_sort.hint'),
    onClick: (e: MouseEvent) => onSort(e, j),
    onDblclick: (e: MouseEvent) => e.stopPropagation(),
    onKeydown: onKey,
  }, [...kids, h('span', { class: 'md-th-sort__mark', 'aria-hidden': 'true' }, state === 'ascending' ? '▲' : state === 'descending' ? '▼' : '')])])
}

function walk(n: MdNode, slots: Map<MdEl, number>): VNodeChild {
  if (!isEl(n)) return props.render(n)
  const m = model.value
  if (m && n === m.head) return h('tr', null, n.children.filter(isEl).map((c, j) => headCell(c, j)))
  const slot = slots.get(n)
  if (m && slot !== undefined) {
    const i = order.value ? order.value[slot] : slot
    return h('tr', { key: i }, m.rows[i].children.map((k) => props.render(k)))
  }
  if (n.tag === 'thead' || n.tag === 'tbody') return h(n.tag, null, n.children.map((k) => walk(k, slots)))
  return props.render(n)
}

/* the table is one render function: its rows are the tree's nodes, reordered */
function Grid(): VNodeChild {
  const m = model.value
  const slots = new Map<MdEl, number>((m ? m.rows : []).map((r, i) => [r, i]))
  return h('div', { class: ['md-table', props.cls], 'data-sortable': m ? 'true' : undefined }, [
    h('table', null, props.node.children.map((k) => walk(k, slots))),
  ])
}
</script>
