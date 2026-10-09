<!-- Spec 113 T006, the doc view, ported from Qto's view-doc (the owner, t1
     519a4ee9: "needs to look exactly how the qto did - a doc with titles and
     paragraphs"). One continuous document: per item a heading with its
     logical number (1 / 1.1 / 1.1.1) and its title, edited in place, the text
     as a paragraph below it, edited in place, then the optional source block
     and image (attrs.src, attrs.img_http_path), both edited in place too: the
     menu's Add code block / Add image put them on the section, the image
     uploaded to the hub (POST /{doc}/images). The document's title is edited
     in place (the hub's rename; cleared, it is the default). Qto's dots control at the far
     left of every title opens the section menu (a click or a right-click, as
     does a right-click on the number or a contents entry): open the branch
     alone, open it as a list (the grid), export it to Markdown or a
     spreadsheet, print it, add a sibling / child / parent, indent, outdent,
     up, down, delete. A '#' permalink per heading, the numbered contents on
     the right (indented by level, collapsible, a click scrolls), a search box
     filtering the items ('/' focuses it, Enter searches every document), and
     print (contents first, then a page break). One read of the whole document (/subtree with no item); every
     edit is one of the hub's ops with the doc rev it read, and a 412 sets
     the session stale (the page shows its reload prompt). -->
<template>
  <div ref="rootEl" class="wsdoc" :class="{ 'wsdoc--toc': tocOpen }" data-test="ws-doc-view">
    <div ref="barEl" class="wsdoc__bar">
      <label class="wsdoc__search">
        <UiIcon name="search" :size="16" />
        <span class="sr-only">{{ t('ws_doctree.search') }}</span>
        <input
          ref="searchEl"
          v-model="search"
          type="search"
          @keydown.enter.prevent="searchAll"
          data-test="ws-doc-search"
          :placeholder="t('ws_doctree.search_placeholder')"
          :aria-label="t('ws_doctree.search')"
        >
      </label>
      <button type="button" class="btn ghost wsdoc__tool" data-test="ws-doc-print-doc" :disabled="!items.length" @click="emit('print', null)">
        <UiIcon name="file-text" :size="16" /><span>{{ t('ws_doctree.print_doc') }}</span>
      </button>
      <button
        type="button"
        class="btn ghost wsdoc__tool"
        data-test="ws-doc-toc-toggle"
        aria-controls="ws-doc-toc"
        :aria-expanded="tocOpen ? 'true' : 'false'"
        @click="toggleToc"
      >
        <UiIcon name="menu" :size="16" /><span>{{ t('ws_doctree.toc') }}</span>
      </button>
    </div>

    <div v-if="hits" class="wsdoc__hits" data-test="ws-doc-hits">
      <div class="wsdoc__hits-head">
        <span>{{ t('ws_doctree.search_all') }}</span>
        <button type="button" class="icon-btn" data-test="ws-doc-hits-close" :aria-label="t('ws_doctree.search_all_close')" @click="hits = null">
          <UiIcon name="x" :size="16" />
        </button>
      </div>
      <p v-if="!hits.length" class="muted">{{ t('ws_doctree.search_all_none') }}</p>
      <ul v-else>
        <li v-for="h in hits" :key="h.doc + h.item">
          <button type="button" class="wsdoc__hit" data-test="ws-doc-hit" @click="openHit(h)">
            <span class="wsdoc__hit-doc">{{ docs.find((d) => d.id === h.doc)?.title || '' }}</span>
            <span>{{ h.title || t('ws_doctree.untitled') }}</span>
          </button>
        </li>
      </ul>
    </div>
    <div v-if="branchItem" class="wsdoc__branch" data-test="ws-doc-branch">
      <span>{{ t('ws_doctree.branch_showing', { n: branchItem.outline, title: branchItem.title || t('ws_doctree.untitled') }) }}</span>
      <button type="button" class="btn ghost" data-test="ws-doc-branch-clear" @click="branch = ''">{{ t('ws_doctree.branch_all') }}</button>
    </div>
    <p v-if="state === 'loading'" class="wsdoc__note muted">{{ t('ws_doctree.loading') }}</p>
    <p v-else-if="state === 'failed'" class="wsdoc__note" role="alert">{{ t('ws_doctree.load_failed') }}</p>
    <div v-else-if="!items.length" class="wsdoc__empty" data-test="ws-doc-empty">
      <p class="muted">{{ t('ws_doctree.empty_doc') }}</p>
      <button type="button" class="btn" data-test="ws-doc-add-first" :disabled="busy" @click="addFirst">
        <UiIcon name="plus" :size="16" /><span>{{ t('ws_doctree.add_first') }}</span>
      </button>
    </div>
    <div v-else class="wsdoc__cols">
      <article class="wsdoc__doc" data-test="ws-doc-doc">
        <h2
          ref="docTitleEl"
          class="wsdoc__doctitle"
          data-test="ws-doc-doctitle"
          contenteditable="plaintext-only"
          spellcheck="false"
          role="textbox"
          :aria-label="t('ws_doctree.edit_doc_title')"
          @keydown.enter.prevent="($event.target as HTMLElement).blur()"
          @keydown.esc.prevent="revertDocTitle"
          @blur="renameDoc"
          v-text="title || t('ws_doctree.default_doc_title')"
        />
        <p v-if="!shown.length" class="wsdoc__note muted" data-test="ws-doc-search-none">{{ t('ws_doctree.search_none') }}</p>
        <section
          v-for="it in shown"
          :key="it.id"
          class="wsdoc__item"
          data-test="ws-doc-row"
          :data-id="it.id"
          :data-outline="it.outline"
          :data-depth="it.depth"
        >
          <h3 :id="anchor(it.id)" class="wsdoc__h">
            <button
              type="button"
              class="wsdoc__dots"
              data-test="ws-doc-menu-btn"
              aria-haspopup="menu"
              :aria-label="t('ws_doctree.actions') + ' ' + it.outline"
              @click="openMenuAt(it, $event)"
              @contextmenu.prevent="openMenu(it, $event.clientX, $event.clientY)"
            >
              <UiIcon name="grip" :size="16" />
            </button>
            <a class="wsdoc__perma" :href="'#' + anchor(it.id)" data-test="ws-doc-permalink" :aria-label="t('ws_doctree.permalink')" @click.prevent="goTo(it.id)">#</a>
            <span
              class="wsdoc__num"
              data-test="ws-doc-num"
              @contextmenu.prevent="openMenu(it, $event.clientX, $event.clientY)"
            >{{ it.outline }}</span>
            <textarea
              class="wsdoc__title"
              data-test="ws-doc-title"
              rows="1"
              maxlength="1000"
              :value="it.title"
              :placeholder="t('ws_doctree.heading_placeholder', { n: it.outline })"
              :aria-label="t('ws_doctree.edit_title') + ' ' + it.outline"
              @input="grow($event.target as HTMLTextAreaElement)"
              @keyup.tab="($event.target as HTMLTextAreaElement).select()"
              @contextmenu.prevent="openMenu(it, $event.clientX, $event.clientY)"
              @keydown.enter.prevent="($event.target as HTMLTextAreaElement).blur()"
              @keydown.esc.prevent="revert($event.target as HTMLTextAreaElement, it.title)"
              @blur="commit(it, 'title', ($event.target as HTMLTextAreaElement).value.replace(/\s+/g, ' ').trim())"
            />
          </h3>
          <textarea
            class="wsdoc__body"
            :class="{ 'wsdoc__body--closed': !paraShown(it) }"
            data-test="ws-doc-text"
            rows="1"
            :value="it.body"
            :placeholder="paraShown(it) ? t('ws_doctree.body_placeholder') : ''"
            @focus="paraOpen.add(it.id)"
            :aria-label="t('ws_doctree.edit_body') + ' ' + it.outline"
            @input="grow($event.target as HTMLTextAreaElement)"
            @keyup.tab="($event.target as HTMLTextAreaElement).select()"
            @keydown.esc.prevent="revert($event.target as HTMLTextAreaElement, it.body)"
            @blur="commit(it, 'body', ($event.target as HTMLTextAreaElement).value)"
          />
          <p v-if="links(it.body).length" class="wsdoc__links" data-test="ws-doc-links">
            <a v-for="(u, i) in links(it.body)" :key="i" :href="u" target="_blank" rel="noopener noreferrer">{{ u }}</a>
          </p>
          <textarea
            v-if="attr(it, 'src') || codeOpen.has(it.id)"
            class="wsdoc__src"
            data-test="ws-doc-src"
            rows="2"
            spellcheck="false"
            :value="attr(it, 'src')"
            :placeholder="t('ws_doctree.code_placeholder')"
            :aria-label="t('ws_doctree.edit_code') + ' ' + it.outline"
            @input="grow($event.target as HTMLTextAreaElement)"
            @keydown.esc.prevent="revert($event.target as HTMLTextAreaElement, attr(it, 'src'))"
            @blur="commitAttrs(it, { src: ($event.target as HTMLTextAreaElement).value })"
          />
          <figure v-if="attr(it, 'img_http_path')" class="wsdoc__fig" data-test="ws-doc-fig">
            <img v-if="imgUrl[attr(it, 'img_http_path')]" loading="lazy" data-test="ws-doc-img" :src="imgUrl[attr(it, 'img_http_path')]" :alt="attr(it, 'img_name') || it.title">
            <figcaption class="wsdoc__figcap">
              <input
                class="wsdoc__caption"
                data-test="ws-doc-img-name"
                maxlength="1000"
                :value="attr(it, 'img_name')"
                :placeholder="t('ws_doctree.image_caption')"
                :aria-label="t('ws_doctree.image_caption') + ' ' + it.outline"
                @keydown.enter.prevent="($event.target as HTMLInputElement).blur()"
                @blur="commitAttrs(it, { img_name: ($event.target as HTMLInputElement).value.trim() })"
              >
              <button type="button" class="icon-btn" data-test="ws-doc-img-remove" :aria-label="t('ws_doctree.image_remove')" :disabled="busy" @click="commitAttrs(it, { img_http_path: '', img_name: '' })">
                <UiIcon name="x" :size="16" />
              </button>
            </figcaption>
          </figure>
        </section>
      </article>
      <nav
        v-show="tocOpen"
        id="ws-doc-toc"
        class="wsdoc__toc"
        data-test="ws-doc-toc"
        :aria-label="t('ws_doctree.toc')"
        :style="{ '--wsdoc-toc-top': tocTop + 'px' }"
      >
        <div class="wsdoc__toc-head">
          <span>{{ t('ws_doctree.toc') }}</span>
          <button type="button" class="icon-btn" data-test="ws-doc-toc-close" :aria-label="t('ws_doctree.toc_hide')" @click="tocOpen = false">
            <UiIcon name="chevron-right" :size="16" />
          </button>
        </div>
        <ol class="wsdoc__toc-list">
          <li
            v-for="it in shown"
            :key="it.id"
            :style="{ '--wsdoc-depth': it.depth - 1 }"
            data-test="ws-doc-toc-item"
            @contextmenu.prevent="openMenu(it, $event.clientX, $event.clientY)"
          >
            <a :href="'#' + anchor(it.id)" @click.prevent="goTo(it.id)"><span class="wsdoc__toc-num">{{ it.outline }}</span> {{ it.title || t('ws_doctree.heading_placeholder', { n: it.outline }) }}</a>
          </li>
        </ol>
      </nav>
    </div>

    <input
      ref="fileEl"
      type="file"
      class="sr-only"
      tabindex="-1"
      aria-hidden="true"
      data-test="ws-doc-img-file"
      :accept="DOC_IMAGE_TYPES.join(',')"
      @change="onImageFile"
    >
    <UiPointMenu
      :open="Boolean(menu)"
      :x="menu?.x ?? 0"
      :y="menu?.y ?? 0"
      :items="menuItems"
      :label="t('ws_doctree.actions')"
      block="wsdoc-menu"
      testid="ws-doc-menu"
      data-test="ws-doc-menu"
      wide
      @close="menu = null"
      @escape="menu = null"
      @choose="choose"
    />
    <UiConfirm
      :open="Boolean(doomed)"
      :title="t('ws_doctree.delete_title')"
      testid="ws-doc-delete"
      :confirm-label="t('ws_doctree.delete_confirm')"
      :busy-label="t('ws_doctree.deleting')"
      :busy="busy"
      @update:open="(v: boolean) => { if (!v) doomed = null }"
      @confirm="confirmDelete"
    >
      <p>{{ t('ws_doctree.delete_body', { title: doomed?.title || t('ws_doctree.untitled') }) }}</p>
    </UiConfirm>
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, shallowRef } from 'vue'
import UiPointMenu from '~/components/UiPointMenu.vue'
import UiConfirm from '~/components/UiConfirm.vue'
import type { PointMenuItem } from '~/components/UiPointMenu.vue'
import {
  DOC_IMAGE_MAX, DOC_IMAGE_TYPES, docMenuItems, editDocAttrs, editDocItem, removeDocItem, runDocOp, moveTarget,
  type DocHead, type DocHit, type DocItem, type DocMenuId, type DocSession, type DocShape,
} from './-doctree-api'

const props = defineProps<{ session: DocSession, root: string, title: string, docs: DocHead[] }>()
const emit = defineEmits<{ print: [item: DocItem | null], list: [outline: string], open: [doc: string, item: string], renamed: [title: string] }>()
const { t } = useI18n({ useScope: 'global' })

/* below this width the contents are a drawer over the document, closed at first */
const NARROW = 760
const ANCHOR = 'ws-doc-'

const rootEl = ref<HTMLElement | null>(null)
const barEl = ref<HTMLElement | null>(null)
/* on a narrow screen the contents drop down under the sticky bar, wherever the document is scrolled */
const tocTop = ref(0)
const items = shallowRef<DocItem[]>([])
const state = ref<'loading' | 'ready' | 'failed'>('loading')
const busy = ref(false)
const search = ref('')
const searchEl = ref<HTMLInputElement | null>(null)
/* Qto's "open as doc": one branch shown alone ('' = the whole document) */
const branch = ref('')
/* Enter in the search box: the hits in every document (null = closed) */
const hits = ref<DocHit[] | null>(null)
/* the level-1 sections whose (empty) paragraph the user opened */
const paraOpen = reactive(new Set<string>())
/** paragraph text is optional at every level; level 1 shows none until asked (owner msgs 9debc0df, ab5b890e) */
const paraShown = (it: DocItem) => it.depth > 1 || Boolean(it.body) || paraOpen.has(it.id)
/* the sections whose (empty) code block the user opened from the menu */
const codeOpen = reactive(new Set<string>())
/* an image's hub path -> the URL the <img> shows (an object URL of the bytes) */
const imgUrl = reactive<Record<string, string>>({})
const docTitleEl = ref<HTMLElement | null>(null)
const fileEl = ref<HTMLInputElement | null>(null)
/* the section the file picker adds an image to */
const imageFor = ref<DocItem | null>(null)
const tocOpen = ref(true)
const menu = ref<{ x: number, y: number, item: DocItem } | null>(null)
const doomed = ref<DocItem | null>(null)

const byId = computed(() => new Map(items.value.map((it) => [it.id, it])))
/** parent id -> its children in order */
const byParent = computed(() => {
  const m = new Map<string, DocItem[]>()
  for (const it of items.value) {
    const sib = m.get(it.parent)
    if (sib) sib.push(it)
    else m.set(it.parent, [it])
  }
  for (const sib of m.values()) sib.sort((a, b) => a.ord - b.ord)
  return m
})

const branchItem = computed(() => (branch.value ? byId.value.get(branch.value) : undefined))

/** the item and everything under it, in document order */
function branchOf(it: DocItem): DocItem[] {
  return items.value.filter((x) => x.id === it.id || x.outline.startsWith(it.outline + '.'))
}

/** Qto's search: the items whose title or text holds the words, or whose number starts with them */
const shown = computed(() => {
  const q = search.value.trim().toLowerCase()
  const all = branchItem.value ? branchOf(branchItem.value) : items.value
  if (!q) return all
  return all.filter((it) => it.title.toLowerCase().includes(q) || it.body.toLowerCase().includes(q) || it.outline.startsWith(q))
})

const anchor = (id: string) => ANCHOR + id
/* Qto's lnkMayBe: the web links in a text, clickable under it */
const LINK = /https?:\/\/[^\s<>"'`)\]]+/g
const links = (text: string) => [...new Set(text.match(LINK) ?? [])].slice(0, 20)
const attr = (it: DocItem, k: string) => {
  const v = it.attrs?.[k]
  return typeof v === 'string' ? v : ''
}

/** resolve each image's src once (the hub path is read with the session's credentials) */
function resolveImages() {
  for (const it of items.value) {
    const p = attr(it, 'img_http_path')
    if (p && !(p in imgUrl)) {
      imgUrl[p] = ''
      void props.session.client.imageSrc(p).then((u) => { imgUrl[p] = u })
    }
  }
}

/** the whole document, in document order (false = it did not load) */
async function load(): Promise<boolean> {
  const s = props.session
  const r = await s.run(() => s.client.subtree(s.doc))
  if (!r) return false
  items.value = r.items
  s.rev.value = r.rev
  resolveImages()
  await nextTick()
  growAll()
  return true
}

/* a textarea as tall as its text; field-sizing: content does it where the browser has it */
const fieldSizing = typeof CSS !== 'undefined' && CSS.supports?.('field-sizing', 'content')
function grow(el: HTMLTextAreaElement) {
  if (fieldSizing) return
  el.style.height = 'auto'
  el.style.height = el.scrollHeight + 'px'
}
function growAll() {
  if (fieldSizing) return
  rootEl.value?.querySelectorAll<HTMLTextAreaElement>('.wsdoc__item textarea').forEach(grow)
}

function revert(el: HTMLTextAreaElement, was: string) {
  el.value = was
  grow(el)
  el.blur()
}

async function commit(it: DocItem, field: 'title' | 'body', value: string) {
  if (it[field] === value) return
  if (await editDocItem(props.session, it, field, value)) items.value = [...items.value]
}

/** a code block or image edit: one attrs edit under the item's rev */
async function commitAttrs(it: DocItem, set: Record<string, string>) {
  if (await editDocAttrs(props.session, it, set)) {
    if ('src' in set && !set.src) codeOpen.delete(it.id)
    items.value = [...items.value]
    resolveImages()
  }
}

function revertDocTitle() {
  const el = docTitleEl.value
  if (!el) return
  el.textContent = props.title || t('ws_doctree.default_doc_title')
  el.blur()
}

/** the document's title, renamed in place under the doc rev; cleared, the hub gives the default */
async function renameDoc() {
  const el = docTitleEl.value
  if (!el) return
  const typed = (el.textContent || '').replace(/\s+/g, ' ').trim()
  if (typed === props.title) return
  const s = props.session
  const r = await s.run(() => s.client.rename(s.doc, s.rev.value, typed))
  if (!r) {
    el.textContent = props.title || t('ws_doctree.default_doc_title')
    return
  }
  s.rev.value = r.rev
  el.textContent = r.title
  emit('renamed', r.title)
}

/** the file picker's image: checked here as the hub checks it, uploaded, then set on the section */
async function onImageFile(e: Event) {
  const input = e.target as HTMLInputElement
  const file = input.files?.[0]
  const it = imageFor.value
  input.value = ''
  imageFor.value = null
  if (!file || !it) return
  const s = props.session
  if (!DOC_IMAGE_TYPES.includes(file.type) || file.size > DOC_IMAGE_MAX) {
    s.error.value = 'ws_doctree.err_image'
    return
  }
  busy.value = true
  try {
    const up = await s.run(() => s.client.uploadImage(s.doc, file))
    if (!up) {
      if (s.error.value === 'ws_doctree.err_failed') s.error.value = 'ws_doctree.err_image'
      return
    }
    await commitAttrs(it, { img_http_path: up.img_http_path, img_name: attr(it, 'img_name') || file.name.replace(/\.[^.]+$/, '') })
  } finally {
    busy.value = false
  }
}

function shapeOf(it: DocItem): DocShape {
  const sib = byParent.value.get(it.parent) ?? []
  const i = sib.findIndex((s) => s.id === it.id)
  return { prev: i > 0 ? sib[i - 1] : undefined, parent: byId.value.get(it.parent), count: sib.length }
}

const menuItems = computed(() => {
  const it = menu.value?.item
  if (!it) return []
  const sh = shapeOf(it)
  const can = (k: 'indent' | 'outdent' | 'up' | 'down') => Boolean(moveTarget(k, it, sh.prev, sh.parent, sh.count))
  const ops = new Map(docMenuItems({ indent: can('indent'), outdent: can('outdent'), up: can('up'), down: can('down') }).map((m) => [m.id, m]))
  const more: PointMenuItem[] = [
    { id: 'add_paragraph', icon: 'pencil', labelKey: 'ws_doctree.menu.add_paragraph' },
    { id: 'add_code', icon: 'file-code', labelKey: 'ws_doctree.menu.add_code' },
    { id: 'add_image', icon: 'file-image', labelKey: attr(it, 'img_http_path') ? 'ws_doctree.menu.replace_image' : 'ws_doctree.menu.add_image' },
    { id: 'open_branch', icon: 'book-open', labelKey: 'ws_doctree.menu.open_branch' },
    { id: 'open_list', icon: 'file-spreadsheet', labelKey: 'ws_doctree.menu.open_list' },
    { id: 'export_md', icon: 'file-code', labelKey: 'ws_doctree.menu.export_md' },
    { id: 'export_csv', icon: 'file', labelKey: 'ws_doctree.menu.export_csv' },
  ]
  for (const m of more) ops.set(m.id, m)
  /* the owner's order (msg dd291fb8): add paragraph, promote, demote, delete, and so on */
  const order = ['add_paragraph', 'add_code', 'add_image', 'outdent', 'indent', 'delete', 'add_sibling', 'add_child', 'add_parent', 'up', 'down',
    'open_branch', 'open_list', 'export_md', 'export_csv', 'print']
  const hasCode = Boolean(attr(it, 'src')) || codeOpen.has(it.id)
  return order.filter((id) => (id !== 'add_paragraph' || !paraShown(it)) && (id !== 'add_code' || !hasCode)).map((id) => ops.get(id)).filter((m): m is PointMenuItem => Boolean(m))
})

/** the menu's view-only entries: open the branch alone or as a list, export it */
async function viewOp(id: string, it: DocItem): Promise<boolean> {
  if (id === 'add_paragraph') {
    paraOpen.add(it.id)
    await nextTick()
    rootEl.value?.querySelector<HTMLTextAreaElement>(`[data-id="${it.id}"] [data-test=ws-doc-text]`)?.focus()
    return true
  }
  if (id === 'add_code') {
    codeOpen.add(it.id)
    await nextTick()
    rootEl.value?.querySelector<HTMLTextAreaElement>(`[data-id="${it.id}"] [data-test=ws-doc-src]`)?.focus()
    return true
  }
  if (id === 'add_image') {
    imageFor.value = it
    fileEl.value?.click()
    return true
  }
  if (id === 'open_branch') {
    branch.value = it.id
    search.value = ''
    await nextTick()
    rootEl.value?.scrollIntoView({ block: 'start' })
    return true
  }
  if (id === 'open_list') {
    emit('list', it.outline)
    return true
  }
  if (id !== 'export_md' && id !== 'export_csv') return false
  const x = await import('./-doctree-export')
  const part = branchOf(it)
  const doc = props.title || t('ws_doctree.default_doc_title')
  if (id === 'export_md') x.saveText(x.exportName(doc, it.outline, 'md'), x.branchToMarkdown(part, t('ws_doctree.untitled')), 'text/markdown;charset=utf-8')
  else x.saveText(x.exportName(doc, it.outline, 'csv'), x.branchToCsv(part, [t('ws_doctree.col_outline'), t('ws_doctree.col_level'), t('ws_doctree.col_title'), t('ws_doctree.col_body')]), 'text/csv;charset=utf-8')
  return true
}

function openMenu(item: DocItem, x: number, y: number) {
  menu.value = { x, y, item }
}
function openMenuAt(item: DocItem, e: MouseEvent) {
  const r = (e.currentTarget as HTMLElement).getBoundingClientRect()
  openMenu(item, r.left, r.bottom)
}

/** focus the title of a new item, its text selected (Qto opens a new node for naming) */
async function editTitle(id: string) {
  await nextTick()
  const el = rootEl.value?.querySelector<HTMLTextAreaElement>(`[data-id="${id}"] [data-test=ws-doc-title]`)
  if (!el) return
  el.scrollIntoView({ block: 'nearest' })
  el.focus()
  el.select()
}

async function choose(id: string) {
  const it = menu.value?.item
  menu.value = null
  if (!it) return
  if (await viewOp(id, it)) return
  const op = id as DocMenuId
  if (op === 'print') return emit('print', it)
  if (op === 'delete') {
    doomed.value = it
    return
  }
  busy.value = true
  try {
    const r = await runDocOp(props.session, op, it, shapeOf(it), t('ws_doctree.untitled'))
    if (!r) return
    search.value = ''
    await load()
    if (r.item) await editTitle(r.item)
  } finally {
    busy.value = false
  }
}

async function addFirst() {
  const s = props.session
  busy.value = true
  try {
    const r = await s.run(() => s.client.add(s.doc, s.rev.value, '', 'child', t('ws_doctree.untitled')))
    if (!r) return
    s.rev.value = r.rev
    await load()
    await editTitle(r.item)
  } finally {
    busy.value = false
  }
}

async function confirmDelete() {
  const it = doomed.value
  if (!it) return
  /* Qto lands on the item before the deleted one */
  const before = items.value[items.value.findIndex((x) => x.id === it.id) - 1]
  busy.value = true
  try {
    if (await removeDocItem(props.session, it)) {
      if (branch.value && !items.value.some((x) => x.id === branch.value && !x.outline.startsWith(it.outline + '.') && x.id !== it.id)) branch.value = ''
      await load()
      if (before && byId.value.has(before.id)) document.getElementById(anchor(before.id))?.scrollIntoView({ block: 'nearest' })
    }
  } finally {
    busy.value = false
    doomed.value = null
  }
}

function narrow() {
  return (rootEl.value?.clientWidth ?? 0) < NARROW
}

function toggleToc() {
  tocTop.value = Math.max(0, Math.round(barEl.value?.getBoundingClientRect().bottom ?? 0))
  tocOpen.value = !tocOpen.value
}

/** a contents link or a permalink: scroll the heading in, the URL carries its anchor */
function goTo(id: string) {
  const el = document.getElementById(anchor(id))
  if (!el) return
  el.scrollIntoView({ block: 'start' })
  history.replaceState(history.state, '', '#' + anchor(id))
  if (narrow()) tocOpen.value = false
}

/** Enter in the search box: Qto's search over every document */
async function searchAll() {
  const q = search.value.trim()
  if (!q) {
    hits.value = null
    return
  }
  const s = props.session
  const r = await s.run(() => s.client.search(q))
  if (r) hits.value = r
}

function openHit(h: DocHit) {
  hits.value = null
  if (h.doc !== props.session.doc) return emit('open', h.doc, h.item)
  search.value = ''
  branch.value = ''
  void nextTick(() => goTo(h.item))
}

/* Qto: '/' focuses the search box, unless the caret is in a field; captured first and
   defaultPrevented, so the top bar's own '/' (slash-focus.mjs) leaves it alone on this page */
function onSlash(e: KeyboardEvent) {
  if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey) return
  const a = document.activeElement as HTMLElement | null
  if (a && (a.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName))) return
  e.preventDefault()
  searchEl.value?.focus()
}

let ro: ResizeObserver | null = null
let lastWidth = 0
onMounted(async () => {
  window.addEventListener('keydown', onSlash, true)
  tocOpen.value = !narrow()
  state.value = (await load()) ? 'ready' : 'failed'
  /* Qto's scrollToHash: a permalink opened from elsewhere lands on its heading */
  const h = decodeURIComponent(location.hash.slice(1))
  if (h.startsWith(ANCHOR)) {
    await nextTick()
    document.getElementById(h)?.scrollIntoView({ block: 'start' })
  }
  if (!fieldSizing && typeof ResizeObserver !== 'undefined' && rootEl.value) {
    ro = new ResizeObserver(() => {
      const w = rootEl.value?.clientWidth ?? 0
      if (w !== lastWidth) {
        lastWidth = w
        growAll()
      }
    })
    ro.observe(rootEl.value)
  }
})
onBeforeUnmount(() => {
  ro?.disconnect()
  window.removeEventListener('keydown', onSlash, true)
})
</script>

<style scoped>
.wsdoc { container-type: inline-size; position: relative; }
.wsdoc__bar {
  position: sticky;
  top: 0;
  z-index: 3;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  padding: 8px 12px;
  background: var(--color-bg);
  border-bottom: 1px solid var(--color-border);
}
.wsdoc__search {
  flex: 1 1 14rem;
  max-width: 28rem;
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 2px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg-2);
  color: var(--color-muted);
}
.wsdoc__search input {
  flex: 1;
  min-width: 0;
  border: 0;
  background: none;
  color: var(--color-fg);
  font: inherit;
  padding: 4px 0;
}
.wsdoc__tool { display: inline-flex; align-items: center; gap: 4px; }
.wsdoc__hits, .wsdoc__branch {
  margin: 8px 12px 0;
  padding: 8px 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  background: var(--color-bg-2);
}
.wsdoc__hits-head { display: flex; align-items: center; justify-content: space-between; color: var(--color-muted); font-weight: 700; }
.wsdoc__hits ul { list-style: none; margin: 4px 0 0; padding: 0; max-height: 40vh; overflow-y: auto; }
.wsdoc__hit {
  display: flex;
  gap: 8px;
  width: 100%;
  padding: 4px 6px;
  border: 0;
  border-radius: var(--radius-sm);
  background: none;
  color: var(--color-fg);
  font: inherit;
  text-align: start;
  cursor: pointer;
}
.wsdoc__hit:hover { background: var(--color-surface-hover); }
.wsdoc__hit-doc { color: var(--color-muted); }
.wsdoc__branch { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px; }
.wsdoc__links { display: flex; flex-wrap: wrap; gap: 4px 12px; margin: 2px 0 0; padding: 0 8px; font-size: 0.875rem; }
.wsdoc__links a { color: var(--color-accent); overflow-wrap: anywhere; }
.wsdoc__note { padding: 12px 16px; }
.wsdoc__empty { display: grid; gap: 12px; justify-items: start; padding: 16px; }

.wsdoc__cols { display: grid; grid-template-columns: minmax(0, 1fr); align-items: start; }
.wsdoc--toc .wsdoc__cols { grid-template-columns: minmax(0, 1fr) minmax(12rem, 27%); }

/* the document: Qto's lft_body, one column of headings and paragraphs */
.wsdoc__doc { padding: 16px clamp(12px, 6%, 64px) 40vh; min-width: 0; }
.wsdoc__item { max-width: 52rem; }
.wsdoc__doctitle {
  max-width: 52rem;
  margin: 0.5rem 0 0.25rem;
  color: var(--color-heading);
  font-size: 1.5rem;
  line-height: 1.3;
  overflow-wrap: anywhere;
}
.wsdoc__h {
  display: flex;
  align-items: flex-start;
  gap: 4px;
  margin: 1.25rem 0 0;
  font-size: 1rem;
  line-height: 1.5;
  scroll-margin-top: 4rem;
}
/* Qto's section control: the dots at the far left of every title, a click or a right-click opens the section menu */
.wsdoc__dots {
  flex: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 1.5rem;
  height: 2rem;
  margin-inline-start: -2.75rem;
  padding: 0;
  border: 0;
  border-radius: var(--radius-sm);
  background: none;
  color: var(--color-muted);
  cursor: context-menu;
}
.wsdoc__dots:hover { color: var(--color-fg); background: var(--color-surface-hover); }
.wsdoc__perma {
  flex: none;
  width: 1.25rem;
  padding-top: 4px;
  color: var(--color-muted);
  text-decoration: none;
  text-align: center;
  opacity: 0;
}
.wsdoc__h:hover .wsdoc__perma, .wsdoc__perma:focus-visible { opacity: 1; }
.wsdoc__num {
  flex: none;
  padding: 4px 4px;
  color: var(--color-accent);
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}
.wsdoc__title, .wsdoc__body {
  display: block;
  width: 100%;
  min-width: 0;
  box-sizing: border-box;
  resize: none;
  overflow: hidden;
  field-sizing: content;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  background: none;
  color: var(--color-fg);
  font: inherit;
}
.wsdoc__title {
  flex: 1;
  padding: 4px 6px;
  color: var(--color-heading);
  font-weight: 700;
  line-height: 1.5;
}
/* a level-1 section starts without a paragraph (owner msg 9debc0df); a click under the heading or "Add paragraph" opens one */
.wsdoc__body--closed:not(:focus) { block-size: 0.75rem; min-height: 0; padding-block: 0; cursor: text; }
.wsdoc__body {
  margin-top: 2px;
  padding: 6px 8px;
  line-height: 1.6;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  min-height: 2rem;
}
.wsdoc__title:hover, .wsdoc__body:hover, .wsdoc__title:focus, .wsdoc__body:focus { border-color: var(--color-border-strong); }
/* an empty title or text shows its placeholder (Heading 1.1, Paragraph text), typed over in place */
.wsdoc__title::placeholder, .wsdoc__body::placeholder { color: var(--color-muted); opacity: 1; font-style: italic; }
.wsdoc__src {
  display: block;
  inline-size: 100%;
  box-sizing: border-box;
  resize: none;
  overflow: hidden;
  field-sizing: content;
  margin: 6px 0;
  padding: 10px 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg-2);
  color: var(--color-fg);
  font: 0.875rem/1.5 var(--font-mono);
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
.wsdoc__fig { margin: 8px 0 16px; color: var(--color-muted); font-size: 0.8rem; font-weight: 700; }
.wsdoc__src:focus { border-color: var(--color-border-strong); }
.wsdoc__fig { display: flex; flex-direction: column-reverse; }
.wsdoc__fig img { display: block; max-width: 100%; height: auto; margin-top: 6px; }
.wsdoc__figcap { display: flex; align-items: center; gap: 4px; }
.wsdoc__caption {
  flex: 1;
  min-width: 0;
  padding: 2px 6px;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  background: none;
  color: inherit;
  font: inherit;
}
.wsdoc__caption:hover, .wsdoc__caption:focus { border-color: var(--color-border-strong); }
.wsdoc__doctitle[contenteditable]:focus { outline: 1px solid var(--color-border-strong); outline-offset: 2px; border-radius: var(--radius-sm); }

/* the contents: Qto's rgt_side_nav, sticky beside the document */
.wsdoc__toc {
  position: sticky;
  top: 3.5rem;
  max-height: calc(100vh - 8rem);
  overflow-y: auto;
  margin: 12px 12px 12px 0;
  padding: 8px 4px 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  background: var(--color-bg-2);
  font-size: 0.875rem;
}
.wsdoc__toc-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 4px 6px 8px;
  color: var(--color-muted);
  font-weight: 700;
}
.wsdoc__toc-list { list-style: none; margin: 0; padding: 0; }
.wsdoc__toc-list li { padding-inline-start: calc(var(--wsdoc-depth, 0) * 0.9rem); }
.wsdoc__toc-list a {
  display: block;
  padding: 3px 8px;
  border-radius: var(--radius-sm);
  color: var(--color-fg);
  text-decoration: none;
  overflow-wrap: anywhere;
}
.wsdoc__toc-list a:hover { background: var(--color-surface-hover); }
.wsdoc__toc-num { color: var(--color-accent); font-variant-numeric: tabular-nums; }

@container (max-width: 760px) {
  .wsdoc--toc .wsdoc__cols { grid-template-columns: minmax(0, 1fr); }
  .wsdoc__doc { padding-inline: 2.75rem 8px; }
  .wsdoc__perma { opacity: 0.5; }
  .wsdoc__toc {
    position: fixed;
    top: var(--wsdoc-toc-top, 0px);
    right: 0;
    z-index: 30;
    width: min(20rem, 88vw);
    max-height: calc(100dvh - var(--wsdoc-toc-top, 0px) - 7rem);
    margin: 0;
    border-radius: var(--radius-md);
    border-width: 0 0 1px 1px;
    box-shadow: var(--focus-3d);
  }
}
</style>
