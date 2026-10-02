<!-- CLE-77884 (Flow + Search rework, topic 635f8072): the compact list of the
     LEFT panel - Search results (lane C) and Flow entries (lane B). Purely
     presentational: the caller owns the items and which one is active, so
     the list and its selection survive the route change an open causes.
     One listbox (ArrowUp/Down wrap, Home/End, Enter opens), each entry one
     scannable block: where-badge, who, where, when, a short snippet with the
     match marked. Item shape: utils/side-hit-list.mjs. Load it lazily - it is
     not part of the first paint (027 budget). Hooks the lane D acceptance
     suite drives: data-testid left-list / left-entry, data-mode, data-msg-id. -->
<template>
  <div
    ref="listEl"
    class="side-hits"
    role="listbox"
    tabindex="0"
    data-testid="left-list"
    :data-test="listTest || undefined"
    :data-mode="mode"
    :aria-label="label"
    :aria-activedescendant="activeIndex >= 0 ? rowId(activeIndex) : undefined"
    @keydown="onKey"
    @focus="onFocus"
  >
    <section v-for="(run, ri) in runs" :key="run.group + ':' + ri" class="side-hits__group" :data-group="run.group || undefined">
      <h3 v-if="run.group" class="side-hits__title">{{ run.group }}</h3>
      <div
        v-for="{ item, index } in run.items"
        :id="rowId(index)"
        :key="item.key"
        role="option"
        class="side-hit"
        :class="{ active: item.key === activeKey, unread: item.unread }"
        :aria-selected="item.key === activeKey ? 'true' : 'false'"
        data-testid="left-entry"
        :data-test="rowTest || undefined"
        :data-key="item.key"
        :data-type="item.type || undefined"
        :data-ts="item.ts || undefined"
        :data-msg-id="item.msgId || item.key"
        :title="item.title || undefined"
        @click="onClick($event, item)"
        @contextmenu="emit('menu', item.key, $event)"
        @pointerdown="emit('press', item.key, $event)"
      >
        <div class="side-hit__head">
          <span v-if="item.badge" class="side-hit__badge" aria-hidden="true">{{ item.badge }}</span>
          <HumanName v-if="item.who && item.who.id" class="side-hit__who" :id="item.who.id" :box="item.who.box || ''" />
          <span v-if="item.where" class="side-hit__where muted">{{ item.where }}</span>
          <span v-if="item.when" class="side-hit__when muted">{{ item.when }}</span>
          <span v-if="item.unread" class="side-hit__dot" data-testid="left-entry-unread" aria-hidden="true" />
        </div>
        <p v-if="segsOf(item).length" class="side-hit__text">
          <template v-for="(s, i) in segsOf(item)" :key="i"><mark v-if="s.mark">{{ s.text }}</mark><template v-else>{{ s.text }}</template></template>
        </p>
      </div>
      <slot name="group-end" :group="run.group" />
    </section>
  </div>
</template>

<script setup lang="ts">
import HumanName from '~/components/HumanName.vue'
import { cycleIndex, groupRuns, itemSegments, type SideHitItem } from '~/utils/side-hit-list.mjs'
import { scrollRowIntoPane } from '~/utils/pane-scroll.mjs'

const props = defineProps<{
  items: SideHitItem[]
  activeKey: string
  label: string
  mode: 'flow' | 'search'
  /** an extra data-test on the listbox / each row, for older suites */
  listTest?: string
  rowTest?: string
}>()
const emit = defineEmits<{
  active: [key: string]
  open: [key: string]
  menu: [key: string, ev: MouseEvent]
  press: [key: string, ev: PointerEvent]
  keydown: [ev: KeyboardEvent, key: string]
}>()

const listEl = ref<HTMLElement | null>(null)
const runs = computed(() => groupRuns(props.items))
const activeIndex = computed(() => props.items.findIndex((i) => i.key === props.activeKey))
const uid = Math.random().toString(36).slice(2, 8)

function rowId(i: number) { return `side-hit-${uid}-${i}` }
function segsOf(item: SideHitItem) { return itemSegments(item) }

function reveal(i: number) {
  nextTick(() => {
    const el = document.getElementById(rowId(i))
    const scroller = el?.closest<HTMLElement>('.sidebar-scroll') || listEl.value
    if (el && scroller) scrollRowIntoPane(scroller, el)
  })
}

function onFocus() {
  if (activeIndex.value < 0 && props.items.length) emit('active', props.items[0].key)
}

/* CLE-77884 (owner: browse the list fast with the keyboard): an open from
   the list leaves the focus ON the list, so Up/Down keep cycling. The place
   it opens focuses its own line (LiveFeed's #<msg> rule, a thread row) a
   moment later; for a short while any such move is handed back, unless the
   reader presses somewhere else first. Not after a tap: a phone has no keys. */
const KEEP_MS = 2000
let releaseKeep: (() => void) | null = null
function keepFocus() {
  releaseKeep?.()
  const list = listEl.value
  if (!list || typeof document === 'undefined') return
  const until = Date.now() + KEEP_MS
  const back = () => {
    if (Date.now() > until) return release()
    if (!list.isConnected) return release()
    const a = document.activeElement
    if (!a || a === document.body || !list.contains(a)) list.focus({ preventScroll: true })
  }
  const onIn = (ev: FocusEvent) => {
    if (ev.target instanceof Node && list.contains(ev.target)) return
    setTimeout(back, 0)
  }
  const timers = [0, 150, 400, 900, 1600].map((ms) => setTimeout(back, ms))
  const release = () => {
    document.removeEventListener('focusin', onIn, true)
    document.removeEventListener('pointerdown', onPress, true)
    document.removeEventListener('keydown', onKeyAny, true)
    timers.forEach(clearTimeout)
    clearTimeout(stop)
    if (releaseKeep === release) releaseKeep = null
  }
  const onPress = (ev: PointerEvent) => {
    if (!(ev.target instanceof Node && list.contains(ev.target))) release()
  }
  /* a key that is not the list's own walk (/, a letter, Tab) is the reader
     going elsewhere */
  const onKeyAny = (ev: KeyboardEvent) => {
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End', 'Enter'].includes(ev.key)) release()
  }
  const stop = setTimeout(release, KEEP_MS)
  document.addEventListener('focusin', onIn, true)
  document.addEventListener('pointerdown', onPress, true)
  document.addEventListener('keydown', onKeyAny, true)
  releaseKeep = release
}
onBeforeUnmount(() => releaseKeep?.())

function onClick(ev: MouseEvent, item: SideHitItem) {
  emit('active', item.key)
  emit('open', item.key)
  if ((ev as PointerEvent).pointerType !== 'touch') keepFocus()
}

function onKey(ev: KeyboardEvent) {
  if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(ev.key)) {
    ev.preventDefault()
    const i = cycleIndex(activeIndex.value, props.items.length, ev.key)
    if (i < 0) return
    emit('active', props.items[i].key)
    reveal(i)
    return
  }
  if (ev.key === 'Enter' && activeIndex.value >= 0) {
    ev.preventDefault()
    emit('open', props.activeKey)
    keepFocus()
    return
  }
  emit('keydown', ev, props.activeKey)
}

/** the caller may hand the focus here (Omnibox ArrowDown, a phone Back) */
function focus() {
  listEl.value?.focus({ preventScroll: true })
  if (activeIndex.value >= 0) reveal(activeIndex.value)
}
defineExpose({ focus, rowEl: (key: string) => {
  const i = props.items.findIndex((x) => x.key === key)
  return i >= 0 ? document.getElementById(rowId(i)) : null
} })
</script>

<style scoped>
.side-hits { outline: none; min-width: 0; max-width: 100%; padding: 2px 0; }
.side-hits:focus-visible { outline: 2px solid var(--color-accent); outline-offset: -2px; border-radius: var(--radius); }
.side-hits__group { margin: 0 0 8px; min-width: 0; }
.side-hits__title {
  font-size: 0.6875rem;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  color: var(--color-muted);
  margin: 4px 8px 2px;
}
.side-hit {
  padding: 6px 8px;
  border-radius: var(--radius);
  cursor: pointer;
  min-width: 0;
  max-width: 100%;
}
.side-hit:hover { background: var(--color-hover, var(--color-surface-2)); }
/* the chosen entry: the shared SELECTED treatment (fill + 3px marker bar) */
.side-hit.active { background: var(--color-selected); box-shadow: inset var(--select-bar-w) 0 0 var(--focus-ring); }
.side-hit__head { display: flex; align-items: baseline; gap: 6px; min-width: 0; font-size: 0.8125rem; }
.side-hit__badge { flex: none; color: var(--color-muted); font-weight: 600; }
.side-hit__who { font-weight: 600; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 0 1 auto; }
.side-hit__where { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 0 1 auto; font-size: 0.75rem; }
.side-hit__when { flex: none; margin-inline-start: auto; font-size: 0.6875rem; }
.side-hit__dot { flex: none; width: 8px; height: 8px; border-radius: 50%; background: var(--color-accent); align-self: center; }
.side-hit.unread .side-hit__who { font-weight: 700; }
/* a short snippet: two lines at most, the match marked */
.side-hit__text {
  margin: 2px 0 0;
  font-size: 0.8125rem;
  line-height: 1.35;
  overflow-wrap: anywhere;
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  overflow: hidden;
}
.side-hit mark { background: var(--color-glow); color: inherit; border-radius: var(--radius-sm); padding: 0 1px; }
/* phones: every entry is a 44 px touch target */
@media (max-width: 820px) {
  .side-hit { min-height: var(--tap, 44px); padding-block: 8px; -webkit-touch-callout: none; }
}
</style>
