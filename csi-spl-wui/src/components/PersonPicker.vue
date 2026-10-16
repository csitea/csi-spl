<!-- SPL-2213 (HUM-10, t1 cb2b515c, msgs 741dcb82 and be2a08cb): picking a
     person is a keyboard drop box. The one person picker of the issues page:
     the Assignee filter, the new-row / row / detail assignee menu and the
     subtask dialog's assignee field.
     Focus it and type: the list shows the people whose name or id holds the
     letters, in any case (utils/person-picker.mjs). Up / Down move the
     highlight, Enter picks it (or the only match left), Escape closes the
     list. The mouse still works: a press opens the list, a click picks.
     mode "field": a closed box that shows the chosen name and opens on a
       press, an arrow or a letter (the filter, the subtask dialog).
     mode "list": the list is always open under a search box; the host shows
       it inside its own popover and closes that on `close` (the menu). -->
<template>
  <div ref="rootEl" class="person-picker" :class="'person-picker--' + mode">
    <input
      ref="inputEl"
      class="person-picker__input"
      :class="inputClass"
      :data-test="test"
      type="text"
      role="combobox"
      autocomplete="off"
      spellcheck="false"
      aria-autocomplete="list"
      :aria-controls="listId"
      :aria-expanded="open ? 'true' : 'false'"
      :aria-activedescendant="activeId"
      :aria-label="label"
      :title="title || undefined"
      :placeholder="mode === 'list' ? label : undefined"
      :value="inputText"
      :disabled="disabled"
      @input="onInput"
      @keydown="onKey"
      @focus="onFocus"
      @blur="onBlur"
      @mousedown="onPress"
    >
    <ul
      v-show="open && rows.length > 0"
      :id="listId"
      class="person-picker__list"
      role="listbox"
      :aria-label="label"
      :style="mode === 'field' ? listStyle : undefined"
      :data-test="test + '-list'"
    >
      <li
        v-for="(p, i) in rows"
        :id="listId + '-' + i"
        :key="p.id || '-'"
        role="option"
        class="person-picker__opt"
        :class="{ 'is-active': i === active, 'person-picker__opt--tall': tall }"
        :data-test="optionTest"
        :data-value="p.id"
        :data-current="p.id === modelValue ? 'true' : undefined"
        :aria-selected="i === active ? 'true' : 'false'"
        @mousedown.prevent
        @mousemove="active = i"
        @click="pick(p.id)"
      >{{ p.label }}</li>
    </ul>
  </div>
</template>

<script setup lang="ts">
import { enterPick, personRows, stepActive } from '~/utils/person-picker.mjs'

type Person = { id: string, label: string }
const props = withDefaults(defineProps<{
  /** every choice, in order: the host puts "All" / "No assignee" first */
  options: Person[]
  modelValue?: string
  /** the control's name (aria-label, placeholder) */
  label: string
  mode?: 'field' | 'list'
  title?: string
  test?: string
  optionTest?: string
  inputClass?: string
  /** a phone sheet: rows are a full tap target tall */
  tall?: boolean
  autofocus?: boolean
  disabled?: boolean
}>(), { modelValue: '', mode: 'field', title: '', test: 'person-picker', optionTest: 'person-picker-option', inputClass: '', tall: false, autofocus: false, disabled: false })
const emit = defineEmits<{ 'update:modelValue': [string], pick: [string], close: [] }>()

const listId = `person-picker-${useId()}`
const inputEl = ref<HTMLInputElement | null>(null)
/* null: nothing typed, the box shows the chosen name */
const query = ref<string | null>(null)
const listOpen = ref(false)
const active = ref(-1)
const listStyle = ref<Record<string, string>>({})
const open = computed(() => props.mode === 'list' || listOpen.value)
const rows = computed(() => personRows(props.options, query.value || ''))
const current = computed(() => props.options.find((p) => p.id === props.modelValue))
const inputText = computed(() => query.value ?? (props.mode === 'field' ? (current.value?.label || '') : ''))
const activeId = computed(() => (open.value && active.value >= 0 && active.value < rows.value.length ? `${listId}-${active.value}` : undefined))

function highlightCurrent() {
  active.value = rows.value.findIndex((p) => p.id === props.modelValue)
}
/* the field's list floats over the page: no table cell or dialog body clips it */
function placeList() {
  const r = inputEl.value?.getBoundingClientRect()
  if (r) listStyle.value = { top: `${Math.round(r.bottom + 2)}px`, left: `${Math.round(r.left)}px`, minWidth: `${Math.round(r.width)}px` }
}
function openList() {
  if (listOpen.value) return
  placeList()
  listOpen.value = true
  highlightCurrent()
}
function closeList() {
  listOpen.value = false
  query.value = null
  active.value = -1
}
function pick(id: string) {
  closeList()
  emit('update:modelValue', id)
  emit('pick', id)
}
function onInput(ev: Event) {
  if (!(ev.target instanceof HTMLInputElement)) return
  query.value = ev.target.value
  if (props.mode === 'field' && !listOpen.value) placeList()
  listOpen.value = true
  active.value = rows.value.length ? 0 : -1
}
function onEscape(ev: KeyboardEvent) {
  /* a closed field leaves Escape to the page or the dialog around it */
  if (props.mode === 'field' && !listOpen.value && query.value === null) return
  ev.preventDefault()
  ev.stopPropagation()
  closeList()
  if (props.mode === 'list') emit('close')
}
function onKey(ev: KeyboardEvent) {
  if (ev.isComposing) return
  if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
    ev.preventDefault()
    ev.stopPropagation()
    if (!open.value) openList()
    else active.value = stepActive(active.value, ev.key === 'ArrowDown' ? 1 : -1, rows.value.length)
  } else if (ev.key === 'Enter') {
    if (!open.value) return
    ev.preventDefault()
    ev.stopPropagation()
    const row = enterPick(rows.value, active.value)
    if (row) pick(row.id)
  } else if (ev.key === 'Escape') {
    onEscape(ev)
  }
}
/* the name is selected on focus, so the first letter starts a fresh search */
function onFocus() {
  if (props.mode === 'field') inputEl.value?.select()
}
function onBlur() {
  if (props.mode === 'field') closeList()
}
function onPress(ev: MouseEvent) {
  if (props.mode !== 'field' || ev.button !== 0 || props.disabled) return
  if (listOpen.value && document.activeElement === inputEl.value) closeList()
  else openList()
}
function onViewport() {
  if (listOpen.value) placeList()
}
watch(active, (i) => {
  if (i < 0) return
  void nextTick(() => document.getElementById(`${listId}-${i}`)?.scrollIntoView?.({ block: 'nearest' }))
})
/* the list mode lives in the host's popover: when it goes, the focus goes
   back to what held it before (the button or the row that opened it) */
const rootEl = ref<HTMLElement | null>(null)
const opener = import.meta.client && props.mode === 'list' ? document.activeElement : null
onMounted(() => {
  if (props.mode === 'list') highlightCurrent()
  if (props.autofocus) inputEl.value?.focus({ preventScroll: true })
  window.addEventListener('scroll', onViewport, true)
  window.addEventListener('resize', onViewport)
})
onBeforeUnmount(() => {
  const back = opener instanceof HTMLElement && opener.isConnected && rootEl.value?.contains(document.activeElement)
  if (back) opener.focus({ preventScroll: true })
  window.removeEventListener('scroll', onViewport, true)
  window.removeEventListener('resize', onViewport)
})
defineExpose({ focus: () => inputEl.value?.focus() })
</script>

<style scoped>
.person-picker { position: relative; display: flex; flex-direction: column; min-width: 0; }
.person-picker__input {
  min-width: 0;
  box-sizing: border-box;
  padding: 4px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg-2);
  color: var(--color-fg);
  font: inherit;
  text-overflow: ellipsis;
}
.person-picker--field .person-picker__input { cursor: pointer; }
.person-picker--field .person-picker__input:focus { cursor: text; }
.person-picker--list .person-picker__input { position: sticky; top: 0; z-index: 1; margin-bottom: 4px; }
.person-picker__list { margin: 0; padding: 0; list-style: none; }
.person-picker--field .person-picker__list {
  position: fixed;
  z-index: calc(var(--z-modal, 50) + 2);
  max-width: min(20rem, calc(100vw - 16px));
  max-height: 16rem;
  overflow: auto;
  padding: 4px;
  box-sizing: border-box;
  background: var(--color-surface);
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm);
  box-shadow: var(--focus-3d);
}
.person-picker__opt {
  padding: 6px 8px;
  border-radius: var(--radius-sm);
  color: var(--color-fg);
  cursor: pointer;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.person-picker__opt.is-active { background: var(--color-selected); }
.person-picker__opt--tall { min-height: var(--tap, 44px); display: flex; align-items: center; }
</style>
