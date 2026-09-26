<!-- One human (or agent) as the feed already names them.
     The HUM id stays in the title. A row too narrow to show the whole name
     opens that title on tap as well as on hover. -->
<template>
  <span class="human-name" :title="tip" @click="onTap">
    <span ref="textEl" class="human-name__text">{{ text }}</span>
    <span v-if="open" class="human-name__pop" role="tooltip">{{ tip }}</span>
  </span>
</template>

<script setup lang="ts">
import { personTitle, shownPerson } from '~/utils/channel-feed.mjs'
import { useHumanNames } from '~/composables/useHumanNames'

const props = defineProps<{ id: string, box?: string }>()
const people = useHumanNames()
const textEl = ref<HTMLElement | null>(null)
const open = ref(false)
const text = computed(() => (props.id ? shownPerson(props.id, props.box, people.names.value) : ''))
const tip = computed(() => (props.id ? personTitle(props.id, props.box, people.names.value) : ''))

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
.human-name__pop {
  position: absolute;
  z-index: 40;
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
