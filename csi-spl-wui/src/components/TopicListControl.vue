<!-- Spec 150 part 1 (row B6): the topic list's filter and sort, on the
     header's second row, left (SPL-5349, option A; FeedHeader, on the
     channel, DM and lobby pages). Two icon buttons; each opens a small
     popover of native radios in one named group, as CardClipControl is
     (Tab lands on the group, the arrows move, Escape closes back to the
     button; a click outside or Tab out closes too).
       - Filter: New / All (panel D5: New = topics with unread).
       - Sort: Last update / Messages / Priority / Created (SPL-6456,
         owner msg 011b15dd: "add also the created attribute").
     An icon shows a dot when its choice is not the default (All, Last
     update), so a filtered list never looks like a short list. The choice is
     kept per browser (useTopicListChoice, panel D6). FeedHeader loads it
     lazily in a fixed-size slot, so the shell's initial chunk does not grow
     and the title does not jump.
     SPL-6613 (owner HUM-10, t1 f7b53cf8, msg 5b8f9db2: "make the search by
     title part of the filter"): on a channel's topic list the Filter popover
     also holds a Title field. Its text goes as typed in one topic_select
     frame (spec 186 4.2, the hub resolves it, 300 ms after the last key);
     the hub's matches narrow the list, a bad pattern or no match is named
     under the field, and the filter icon's dot shows while it narrows. -->
<template>
  <div
    ref="root"
    class="tl-ctl"
    role="group"
    :aria-label="t('feed.topic_list.label')"
    data-testid="topic-list-control"
    :data-filter="filter"
    :data-sort="sort"
    @focusout="onFocusOut"
  >
    <span v-for="g in GROUPS" :key="g.id" class="tl-ctl__item">
      <button
        :ref="(el) => { triggers[g.id] = el as HTMLElement | null }"
        type="button"
        class="tl-ctl__btn"
        :class="{ 'tl-ctl__btn--set': g.id === 'filter' ? filtered || titled : sorted }"
        :data-testid="`topic-list-${g.id}`"
        aria-haspopup="true"
        :aria-expanded="open === g.id ? 'true' : 'false'"
        :aria-controls="open === g.id ? `${uid}-${g.id}` : undefined"
        :aria-label="t(g.label)"
        :title="t(g.label)"
        @click="toggle(g.id)"
      >
        <UiIcon :name="g.icon" size="1em" />
        <span v-if="g.id === 'filter' ? filtered || titled : sorted" class="tl-ctl__dot" aria-hidden="true" :data-testid="`topic-list-${g.id}-dot`" />
      </button>
      <div
        v-if="open === g.id"
        :id="`${uid}-${g.id}`"
        :ref="(el) => { pops[g.id] = el as HTMLElement | null }"
        class="tl-ctl__pop"
        @keydown.esc.stop.prevent="close(true)"
      >
        <div class="tl-ctl__radios" role="radiogroup" :aria-label="t(g.label)" :data-testid="`topic-list-${g.id}-group`">
          <label v-for="o in g.options" :key="o.value" class="tl-ctl__opt" :class="{ 'tl-ctl__opt--on': current(g.id) === o.value }">
            <input
              type="radio"
              :name="`${uid}-${g.id}`"
              :value="o.value"
              :checked="current(g.id) === o.value"
              :data-testid="`topic-list-${g.id}-${o.value}`"
              @change="choose(g.id, o.value)"
            />
            <span>{{ t(o.label) }}</span>
          </label>
        </div>
        <div v-if="g.id === 'filter' && titleOn" class="tl-ctl__title">
          <label :for="`${uid}-title`" class="tl-ctl__title-label">{{ t('feed.topic_list.filter_title') }}</label>
          <input
            :id="`${uid}-title`"
            type="text"
            class="tl-ctl__title-field"
            data-testid="topic-list-filter-title"
            :value="title"
            spellcheck="false"
            autocomplete="off"
            @input="onTitle(($event.target as HTMLInputElement).value)"
            @keydown.enter.prevent
          />
          <p v-if="titleNote" class="tl-ctl__note" :class="{ 'is-error': titleBad }" role="status" data-testid="topic-list-filter-title-note">{{ titleNote }}</p>
        </div>
      </div>
    </span>
  </div>
</template>

<script setup lang="ts">
import { useTopicListChoice } from '~/composables/useTopicListChoice'
import { useTopicSelect, type PatternOutcome } from '~/composables/useTopicSelect'
import type { UiIconName } from '~/utils/uiIcons'

type GroupId = 'filter' | 'sort'
const GROUPS: { id: GroupId, icon: UiIconName, label: string, options: { value: string, label: string }[] }[] = [
  {
    id: 'filter',
    icon: 'filter',
    label: 'feed.topic_list.filter',
    options: [
      { value: 'all', label: 'feed.topic_list.filter_all' },
      { value: 'new', label: 'feed.topic_list.filter_new' },
    ],
  },
  {
    id: 'sort',
    icon: 'sort',
    label: 'feed.topic_list.sort',
    options: [
      { value: 'last', label: 'feed.topic_list.sort_last' },
      { value: 'messages', label: 'feed.topic_list.sort_count' },
      { value: 'priority', label: 'feed.topic_list.sort_prio' },
      { value: 'created', label: 'feed.topic_list.sort_created' },
    ],
  },
]

const { t } = useI18n({ useScope: 'global' })
const { filter, sort, setFilter, setSort, filtered, sorted, title, setTitle, titled, titleOn } = useTopicListChoice()
/* one pair of radio groups per control on the page */
const uid = `topic-list-${useId()}`
const root = ref<HTMLElement | null>(null)
const triggers: Record<string, HTMLElement | null> = {}
const pops: Record<string, HTMLElement | null> = {}
const open = ref<GroupId | ''>('')

function current(id: GroupId) {
  return id === 'filter' ? filter.value : sort.value
}

function choose(id: GroupId, value: string) {
  if (id === 'filter') setFilter(value)
  else setSort(value)
}

/* opening puts focus on the checked radio, so the arrows move at once */
async function toggle(id: GroupId) {
  if (open.value === id) return close(false)
  open.value = id
  await nextTick()
  pops[id]?.querySelector<HTMLInputElement>('input:checked')?.focus()
}

function close(refocus: boolean) {
  const was = open.value
  open.value = ''
  if (refocus && was) triggers[was]?.focus()
}

/* SPL-6613: the title field. The hub resolves the text 300 ms after the last
   key (spec 186 4.1: one frame per 300 ms); the note names a bad pattern,
   no match or a failure. FeedHeader re-resolves it on a page and ends it. */
const TITLE_DEBOUNCE_MS = 300
const { filterByTitle } = useTopicSelect()
const titleOutcome = ref<PatternOutcome | null>(null)
const titleBad = computed(() => Boolean(titleOutcome.value?.bad))
const titleNote = computed(() => {
  const o = titleOutcome.value
  if (!o) return ''
  if (o.bad) return t('topic_select.bad_pattern', { line: o.bad.line, reason: o.bad.reason })
  if (o.none) return t('topic_select.none')
  return o.error
})
let titleTimer: ReturnType<typeof setTimeout> | undefined
function onTitle(value: string) {
  setTitle(value)
  clearTimeout(titleTimer)
  titleTimer = setTimeout(() => { void resolveTitle(value) }, TITLE_DEBOUNCE_MS)
}
async function resolveTitle(value: string) {
  const out = await filterByTitle(value)
  if (out || !value.trim()) titleOutcome.value = out
}
onBeforeUnmount(() => clearTimeout(titleTimer))

/* Tab out of the control, or a click elsewhere, closes the popover */
function onFocusOut(e: FocusEvent) {
  const next = e.relatedTarget as Node | null
  if (next && root.value?.contains(next)) return
  open.value = ''
}

function onDocDown(e: PointerEvent) {
  if (open.value && root.value && !root.value.contains(e.target as Node)) open.value = ''
}
onMounted(() => document.addEventListener('pointerdown', onDocDown))
onBeforeUnmount(() => document.removeEventListener('pointerdown', onDocDown))
</script>

<style scoped>
.tl-ctl {
  display: inline-flex;
  flex-shrink: 0;
  gap: 2px;
}
.tl-ctl__item { position: relative; display: inline-flex; }
.tl-ctl__btn {
  position: relative;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  /* SPL-5349: the card-size control's cell size, 26 x 16 px drawn (plus
     the 1 px border), 35 x 30 on a phone */
  box-sizing: border-box;
  width: 26px;
  height: 18px;
  padding: 0;
  /* the icon is 1em, so it follows the font size setting (as CardClipControl) */
  font-size: 0.75rem;
  color: var(--color-muted);
  background: none;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  cursor: pointer;
}
.tl-ctl__btn--set,
.tl-ctl__btn[aria-expanded='true'] { color: var(--color-fg); background: var(--color-selected); }
.tl-ctl__btn:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: calc(-1 * var(--focus-ring-w));
}
.tl-ctl__dot {
  position: absolute;
  top: 2px;
  inset-inline-end: 3px;
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--color-accent);
}
.tl-ctl__pop {
  position: absolute;
  top: calc(100% + 4px);
  /* SPL-5349: the buttons start the row, so the popover opens toward the end */
  inset-inline-start: 0;
  z-index: var(--z-overlay, 1000);
  display: flex;
  flex-direction: column;
  min-width: max-content;
  padding: 4px;
  background: var(--color-bg-2);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md, 6px);
  box-shadow: 0 12px 32px rgb(0 0 0 / .35);
}
.tl-ctl__opt {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 4px 8px;
  font-size: 0.875rem;
  border-radius: var(--radius-sm, 4px);
  cursor: pointer;
  white-space: nowrap;
}
.tl-ctl__opt--on { background: var(--color-selected); font-weight: 600; }
.tl-ctl__opt:has(input:focus-visible) {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: calc(-1 * var(--focus-ring-w));
}
.tl-ctl__opt input { margin: 0; }
.tl-ctl__radios { display: flex; flex-direction: column; }
/* SPL-6613: the title field under New / All */
.tl-ctl__title { display: flex; flex-direction: column; gap: 4px; margin-top: 4px; padding: 6px 8px 4px; border-top: 1px solid var(--color-border); }
.tl-ctl__title-label { font-size: 0.8125rem; color: var(--color-muted); }
.tl-ctl__title-field { width: 16rem; max-width: calc(100vw - 48px); box-sizing: border-box; font-family: var(--font-mono, monospace); font-size: 0.875rem; }
.tl-ctl__note { margin: 0; max-width: 16rem; font-size: 0.8125rem; white-space: normal; }
.tl-ctl__note.is-error { color: var(--color-danger); }
/* SPL-989: on a phone each button keeps a 44 px tall target - an
   invisible box standing out of the drawn one (SPL-5349) */
@media (max-width: 820px) {
  .tl-ctl__btn { width: 35px; height: 32px; font-size: 0.875rem; }
  .tl-ctl__btn::after { content: ''; position: absolute; inset: 50% 0 auto; height: var(--tap); transform: translateY(-50%); }
  .tl-ctl__opt { min-height: var(--tap); }
  .tl-ctl__title-field { min-height: var(--tap); font-size: 1rem; }
}
</style>
