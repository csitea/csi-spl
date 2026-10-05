<!-- The tenant drop box (specs/026 §6), above 820 px. Owner 2026-09-27 (topic
     d5504c2b): it sits in the top bar where the spool-hub brand text was,
     just before the theme palette icon; the brand text is gone. One
     membership: one row, choosing it changes nothing. Several: every
     membership, and choosing one switches the session's tenant.
     CLE-34991: one slim row, a glyph instead of a visible caption; the
     caption is the select's name and hovering explains what a tenant is.
     The closed select is as wide as the widest option, then about one
     letter (7px, owner topic 72773b61), then the arrow, measured in the select's own font.
     SPL-71: a drop box, not a dropdown menu - the name and the arrow sit
     in one bordered box, and pressing anywhere in it opens the list.
     Rows come in the hub's order (tenants.sort_order, rdb 0051).
     HUM-10 (topic 20a30816): a searchable combobox, not a native select -
     typing filters the list by a case-insensitive "contains" on the name,
     Up/Down move the highlight, Enter switches to the highlighted row (or
     the only one left), Esc closes the list and puts the current name back.
     On a phone TopBarTenant is the switcher and this one is not shown. -->
<template>
  <div class="tenant-drop">
    <div ref="tenantSwitcherEl" class="tenant-switcher" data-testid="tenant-switcher" :title="tenantHintText">
      <span class="tenant-switcher__icon"><UiIcon name="building" :size="16" /></span>
      <span
        class="tenant-switcher__field"
        data-testid="tenant-switcher-box"
        :style="{ gap: (TENANT_DESKTOP_ARROW_GAP_PX - TENANT_TEXT_PAD_PX) + 'px' }"
        @mousedown="onTenantBoxPress"
      >
      <input
        ref="tenantSelectEl"
        class="tenant-switcher__select"
        data-testid="tenant-switcher-select"
        type="text"
        role="combobox"
        autocomplete="off"
        spellcheck="false"
        aria-autocomplete="list"
        :aria-controls="TENANT_LIST_ID"
        :aria-expanded="listOpen ? 'true' : 'false'"
        :aria-activedescendant="activeId"
        :value="inputText"
        :placeholder="t('sidebar.tenant')"
        :readonly="!tenantBox.canSwitch"
        :aria-label="t('sidebar.tenant')"
        aria-describedby="tenant-switcher-hint"
        :aria-busy="switching ? 'true' : undefined"
        :style="tenantSelectStyle"
        @input="onTenantInput"
        @keydown="onTenantKey"
        @focus="selectTenantText"
        @blur="closeTenantList"
      >
      <svg
        class="tenant-switcher__arrow"
        data-testid="tenant-switcher-arrow"
        viewBox="0 0 8 6"
        aria-hidden="true"
        focusable="false"
      >
        <path d="M0 0 H8 L4 6 Z" />
      </svg>
      <ul
        v-show="listOpen && shownRows.length > 0"
        :id="TENANT_LIST_ID"
        class="tenant-switcher__list"
        data-testid="tenant-switcher-list"
        role="listbox"
        :aria-label="t('sidebar.tenant')"
      >
        <li
          v-for="(o, i) in shownRows"
          :id="TENANT_LIST_ID + '-' + i"
          :key="o.id"
          role="option"
          class="tenant-switcher__option"
          :class="{ 'is-active': i === activeIndex }"
          data-testid="tenant-switcher-option"
          :data-tenant="o.id"
          :aria-selected="o.id === tenantBox.selected ? 'true' : 'false'"
          @mousedown.prevent
          @mousemove="activeIndex = i"
          @click="pickTenant(o.id)"
        >{{ o.label || t('sidebar.tenant') }}</li>
      </ul>
      </span>
      <span id="tenant-switcher-hint" class="sr-only" data-testid="tenant-switcher-hint">{{ tenantHintText }}</span>
    </div>
    <p v-if="switchFailed" class="tenant-switcher__error" role="alert" data-testid="tenant-switch-error">{{ t('sidebar.tenant_switch_failed') }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useTenantSwitch } from '~/composables/useTenantSwitch'
import { MOBILE_STACK_QUERY } from '~/utils/mobile-stack.mjs'
import { measureControlText, TENANT_DESKTOP_ARROW_GAP_PX, TENANT_TEXT_PAD_PX, tenantDrawnLabels, tenantHint, tenantMatches, tenantSwitchOptions, widestLabelWidth } from '~/utils/tenant-switcher.mjs'

const TENANT_LIST_ID = 'tenant-switcher-list'
const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const api = useSpoolApi()
const tenantBox = computed(() => tenantSwitchOptions(session.claims, api.tenant))
const tenantHintText = computed(() => tenantHint(tenantBox.value, t))
const tenantSelectEl = ref<HTMLInputElement | null>(null)
const tenantSwitcherEl = ref<HTMLElement | null>(null)
const tenantTextPx = ref(0)
const tenantSelectStyle = computed(() => {
  const text = tenantTextPx.value
  if (!(text > 0)) return undefined
  return { width: (text + 2 * TENANT_TEXT_PAD_PX) + 'px', paddingInline: TENANT_TEXT_PAD_PX + 'px' }
})
/* The box is only as wide as the widest name in its own font. The arrow
   is the next flex item, TENANT_DESKTOP_ARROW_GAP_PX after that edge, so a clamped
   bar cannot slide the arrow back over the name. Re-measured when the list,
   the font-size setting (html data-font-size), or the viewport changes.
   W4 (perf round 4): at <= 820 px the box is display:none (TopBarTenant is
   the phone's switcher), so nothing is measured there; the viewport
   listener measures once the box is shown.
   E14 (perf edition 20261004): every measure runs in a one-shot
   ResizeObserver callback, i.e. after the frame's own layout and before its
   paint. The computed-font read then finds style and layout clean (no forced
   layout at mount), and the width still lands before the first paint (no
   jump). Observing again queues one more callback after the next layout. */
function applyTenantSelectWidth() {
  const sel = tenantSelectEl.value
  if (!sel) return
  if (tenantBoxHidden(sel)) return
  const labels = tenantDrawnLabels(tenantBox.value.options, t('sidebar.tenant'))
  const text = widestLabelWidth(labels, (label) => measureControlText(sel, label))
  if (labels.some((label) => label.length > 0) && !(text > 0)) return
  if (Math.abs(tenantTextPx.value - text) > 0.01) tenantTextPx.value = text
}
function tenantBoxHidden(sel: HTMLElement) {
  const view = sel.ownerDocument?.defaultView
  return !!view && typeof view.matchMedia === 'function' && view.matchMedia(MOBILE_STACK_QUERY).matches
}
let tenantWidthRo: ResizeObserver | null = null
function scheduleTenantSelectWidth() {
  const sel = tenantSelectEl.value
  if (!sel) return
  if (!tenantWidthRo) return applyTenantSelectWidth()
  tenantWidthRo.observe(sel)
}
watch(
  () => tenantDrawnLabels(tenantBox.value.options, t('sidebar.tenant')).join('\n'),
  () => scheduleTenantSelectWidth(),
)
let tenantWidthMq: MediaQueryList | null = null
let tenantFontObs: MutationObserver | null = null
function onTenantWidthViewport() { scheduleTenantSelectWidth() }
onMounted(() => {
  const doc = tenantSwitcherEl.value?.ownerDocument
  const view = doc?.defaultView
  /* one-shot: disconnect first, so the width set here is not observed again
     in the same frame (no "loop completed with undelivered notifications") */
  if (view && typeof view.ResizeObserver === 'function') {
    tenantWidthRo = new view.ResizeObserver((_entries, ro) => {
      ro.disconnect()
      applyTenantSelectWidth()
    })
  }
  scheduleTenantSelectWidth()
  /* a web font still loading changes the width once it is in */
  if (doc?.fonts && doc.fonts.status !== 'loaded') void doc.fonts.ready.then(() => scheduleTenantSelectWidth())
  if (doc?.documentElement && typeof MutationObserver === 'function') {
    tenantFontObs = new MutationObserver(() => scheduleTenantSelectWidth())
    tenantFontObs.observe(doc.documentElement, { attributes: true, attributeFilter: ['data-font-size'] })
  }
  if (!view) return
  tenantWidthMq = view.matchMedia(MOBILE_STACK_QUERY)
  tenantWidthMq.addEventListener('change', onTenantWidthViewport)
})
onBeforeUnmount(() => {
  tenantWidthRo?.disconnect()
  tenantWidthRo = null
  tenantFontObs?.disconnect()
  tenantWidthMq?.removeEventListener('change', onTenantWidthViewport)
})

/* specs/026 §6: a member of several tenants switches here (useTenantSwitch,
   shared with the phone top bar's sheet, SPL-995). */
const tenantSwitch = useTenantSwitch()
const switching = tenantSwitch.switching
const switchFailed = tenantSwitch.failed

/* HUM-10: the combobox. `query` is what the human typed (null: nothing typed,
   the box shows the current name); the list shows the rows whose name
   contains it, case-insensitively. Among several, the blank placeholder row
   is not a choice; a single row is always listed, as the select listed it. */
const listOpen = ref(false)
const query = ref<string | null>(null)
const activeIndex = ref(-1)
const tenantRows = computed(() => (tenantBox.value.canSwitch ? tenantBox.value.options.filter((o: { id: string }) => o.id) : tenantBox.value.options))
const shownRows = computed(() => tenantRows.value.filter((o: { id: string, label: string }) => tenantMatches(o.label || o.id, query.value || '')))
const inputText = computed(() => query.value ?? tenantSwitch.name.value)
const activeId = computed(() => (listOpen.value && activeIndex.value >= 0 && activeIndex.value < shownRows.value.length ? TENANT_LIST_ID + '-' + activeIndex.value : undefined))

function openTenantList() {
  if (listOpen.value) return
  listOpen.value = true
  activeIndex.value = Math.max(0, shownRows.value.findIndex((o: { id: string }) => o.id === tenantBox.value.selected))
  if (!shownRows.value.length) activeIndex.value = -1
}
/* Esc, a blur or a pick: the list shuts and the box shows the current name */
function closeTenantList() {
  listOpen.value = false
  query.value = null
  activeIndex.value = -1
}
function onTenantInput(ev: Event) {
  const el = ev.target
  if (!(el instanceof HTMLInputElement)) return
  query.value = el.value
  listOpen.value = true
  activeIndex.value = shownRows.value.length ? 0 : -1
}
function moveActive(step: number) {
  const n = shownRows.value.length
  if (!n) { activeIndex.value = -1; return }
  activeIndex.value = activeIndex.value < 0 ? (step > 0 ? 0 : n - 1) : (activeIndex.value + step + n) % n
}
function onTenantKey(ev: KeyboardEvent) {
  if (ev.isComposing) return
  if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
    ev.preventDefault()
    if (!listOpen.value) openTenantList()
    else moveActive(ev.key === 'ArrowDown' ? 1 : -1)
  } else if (ev.key === 'Enter') {
    if (!listOpen.value) return
    ev.preventDefault()
    const rows = shownRows.value
    const row = rows[activeIndex.value] || (rows.length === 1 ? rows[0] : null)
    if (row) void pickTenant(row.id)
  } else if (ev.key === 'Escape') {
    if (!listOpen.value && query.value === null) return
    ev.preventDefault()
    ev.stopPropagation()
    closeTenantList()
  }
}
/* SPL-71: a press anywhere in the box (the arrow, the padding, the name)
   opens the list; a press on an open box's arrow or padding shuts it. */
function onTenantBoxPress(ev: MouseEvent) {
  const sel = tenantSelectEl.value
  if (!sel || ev.button !== 0) return
  const target = ev.target as Node
  if (target instanceof Element && target.closest('[role=listbox]')) return
  if (target === sel && document.activeElement === sel) {
    openTenantList()
    return
  }
  ev.preventDefault()
  sel.focus()
  if (target !== sel && listOpen.value) closeTenantList()
  else openTenantList()
}
/* the name is selected on focus, so typing starts a fresh search */
function selectTenantText(ev: FocusEvent) {
  if (ev.target instanceof HTMLInputElement) ev.target.select()
}
async function pickTenant(id: string) {
  closeTenantList()
  await tenantSwitch.switchTo(id)
}
</script>

<style scoped>
.tenant-drop {
  position: relative;
  display: flex;
  align-items: center;
  flex: 0 1 auto;
  min-width: 0;
}
/* Compact drop box: one slim row, a glyph and the box, no
   caption. The select's width is the widest option in its own font, plus
   3px, plus the arrow (set from script, not a fixed px width). max-width
   keeps the row inside the bar. SPL-71: the name and the arrow sit in one
   bordered box (__field), a drop box rather than a dropdown menu. */
.tenant-switcher {
  position: relative;
  display: flex;
  align-items: center;
  gap: 4px;
  flex: 0 1 auto;
  width: max-content;
  max-width: 20rem;
  min-width: 0;
  box-sizing: border-box;
  padding: 0 4px;
  border-radius: var(--radius-sm);
  color: var(--color-muted);
  /* owner 2026-09-27: the tenant text a bit bigger than the sidebar's 0.75rem */
  font-size: 0.875rem;
}
.tenant-switcher:hover { background: var(--color-surface); color: var(--color-fg); }
.tenant-switcher__icon { flex: 0 0 auto; display: inline-flex; }
/* owner 2026-09-27: the box 4 px wider than before - 2px more on each side */
.tenant-switcher__field {
  position: relative;
  display: inline-flex;
  align-items: center;
  flex: 0 0 auto;
  min-width: 0;
  box-sizing: border-box;
  height: 28px;
  padding: 0 8px;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  cursor: pointer;
}
.tenant-switcher__error {
  position: absolute;
  top: 100%;
  inset-inline-start: 0;
  margin: 2px 0 0;
  white-space: nowrap;
  font-size: 0.6875rem;
  color: var(--color-danger);
}
.tenant-switcher__select {
  flex: 0 0 auto;
  box-sizing: border-box;
  min-height: 26px;
  height: 26px;
  cursor: pointer;
  padding: 0;
  background: transparent;
  color: var(--color-fg);
  border: 0;
  border-radius: var(--radius-sm);
  font: inherit;
  font-weight: 600;
  line-height: 1.2;
  text-align: start;
  text-overflow: ellipsis;
  appearance: none;
  -webkit-appearance: none;
}
.tenant-switcher__select:not([readonly]):focus { cursor: text; }
.tenant-switcher__select::placeholder { color: var(--color-fg); opacity: 1; }
.tenant-switcher__arrow {
  flex: 0 0 auto;
  width: 0.65em;
  height: 0.5em;
  display: block;
  pointer-events: none;
  fill: currentColor;
  color: var(--color-fg);
}
/* SPL-980 (owner 2026-09-27, topic 72773b61): the OPEN list keeps 2 px
   between every entry - the selected one too - and the list's border, each
   row 4 px before and after its name, and the rows carry the theme's
   colours. HUM-10: the page draws the list (the combobox's listbox) under
   the box. */
.tenant-switcher__list {
  position: absolute;
  top: 100%;
  inset-inline-start: -1px;
  z-index: var(--z-overlay, 1000);
  box-sizing: border-box;
  min-width: calc(100% + 2px);
  max-width: 20rem;
  max-height: min(60vh, 24rem);
  overflow-y: auto;
  margin: 4px 0 0;
  padding: 2px;
  list-style: none;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm);
  background: var(--color-bg-2);
  color: var(--color-fg);
  box-shadow: 0 4px 14px rgba(0, 0, 0, 0.18);
  cursor: default;
}
.tenant-switcher__option {
  display: flex;
  align-items: center;
  box-sizing: border-box;
  min-block-size: 26px;
  padding-block: 2px;
  padding-inline: 4px;
  border-radius: var(--radius-sm);
  background-color: var(--color-bg-2);
  color: var(--color-fg);
  font-weight: 600;
  white-space: nowrap;
  cursor: pointer;
}
.tenant-switcher__option.is-active { background-color: var(--color-surface-hover); }
.tenant-switcher__option[aria-selected='true'] {
  background-color: var(--color-accent);
  color: var(--color-on-accent);
}
.tenant-switcher__option[aria-selected='true'].is-active { box-shadow: inset 0 0 0 2px var(--color-fg); }
/* SPL-995: on a phone the switcher is TopBarTenant - never shown twice */
@media (max-width: 820px) {
  .tenant-drop { display: none; }
}
</style>
