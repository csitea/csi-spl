<!-- One human (or agent) as the feed already names them.
     The HUM id stays in the title. A row too narrow to show the whole name
     opens that title on tap as well as on hover.
     `stacked` (specs/058, CLE-77932): an agent's box goes on its own small
     line under the id, so a narrow row clips neither - CLE-001@box-desk and
     CLE-001@sat both read "CLE-001@…" on one clipped line. -->
<template>
  <span class="human-name" :class="{ 'human-name--stacked': split }" :title="tip" @click="onTap">
    <span ref="textEl" class="human-name__text">{{ split ? split.id : text }}</span>
    <span v-if="split" class="human-name__box" data-test="human-name-box">{{ split.box }}</span>
    <span v-if="open" class="human-name__pop" role="tooltip">{{ tip }}</span>
  </span>
</template>

<script setup lang="ts">
import { personTitle, shownPerson } from '~/utils/channel-feed.mjs'
import { useHumanNames } from '~/composables/useHumanNames'

const props = defineProps<{ id: string, box?: string, stacked?: boolean }>()
const people = useHumanNames()
const textEl = ref<HTMLElement | null>(null)
const open = ref(false)
const text = computed(() => (props.id ? shownPerson(props.id, props.box, people.names.value) : ''))
const tip = computed(() => (props.id ? personTitle(props.id, props.box, people.names.value) : ''))
/* an agent only: a human on box-wui is named, never id@box */
const split = computed(() => (props.stacked && props.id && props.box && !/^(HUM|GST)-/.test(props.id) ? { id: props.id, box: '@' + props.box } : null))

function clipped() {
  const node = textEl.value
  if (!node) return false
  return node.scrollWidth > node.clientWidth + 1 || node.scrollHeight > node.clientHeight + 1
}

function onTap(ev: MouseEvent) {
  if (!clipped() && !open.value) return
  ev.preventDefault()
  ev.stopPropagation()
  open.value = !open.value
}

function onDoc(ev: Event) {
  const root = textEl.value?.parentElement
  if (!open.value || !root) return
  if (ev.target instanceof Node && root.contains(ev.target)) return
  open.value = false
}

watch(open, (v) => {
  if (v) document.addEventListener('pointerdown', onDoc, true)
  else document.removeEventListener('pointerdown', onDoc, true)
})
onBeforeUnmount(() => document.removeEventListener('pointerdown', onDoc, true))
</script>

<style scoped>
.human-name {
  position: relative;
  display: inline-block;
  max-width: 100%;
  min-width: 0;
  vertical-align: bottom;
}
.human-name__text {
  display: block;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
/* never narrower than the id (a wide unread badge, "50/954", clipped the
   owner's CLE-001 row to "CLE-…"), as wide as id + box when there is room.
   The box line breaks anywhere, so it adds ~one character to the min-content
   width the row may shrink to; max-height keeps just its first line. */
/* doubled class: beats the rail's `.nav-item .label { min-width: 0 }` */
.human-name.human-name--stacked {
  display: inline-flex;
  flex-direction: column;
  min-width: auto;
  line-height: 1.15;
}
.human-name__box {
  display: block;
  overflow: hidden;
  word-break: break-all;
  max-height: 1.15em;
  font-size: 0.75em;
  opacity: 0.75;
}
.human-name__pop {
  position: absolute;
  z-index: var(--z-popover);
  inset-inline-start: 0;
  top: calc(100% + 4px);
  max-width: 240px;
  padding: 4px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
  white-space: normal;
  overflow: visible;
  font-weight: 500;
}
</style>
