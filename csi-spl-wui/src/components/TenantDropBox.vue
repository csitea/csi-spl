<!-- The tenant drop box (specs/026 §6), above 820 px. Owner 2026-09-27 (topic
     d5504c2b): it sits in the top bar where the spool-hub brand text was,
     just before the theme palette icon; the brand text is gone. One
     membership: one row, choosing it changes nothing. Several: every
     membership, and choosing one switches the session's tenant.
     CLE-34991: one slim row, a glyph instead of a visible caption; the
     caption is the select's name and hovering explains what a tenant is.
     The closed select is as wide as the widest option, then 3px, then
     the arrow, measured in the select's own font.
     SPL-71: a drop box, not a dropdown menu - the name and the arrow sit
     in one bordered box, and pressing anywhere in it opens the list.
     Rows come in the hub's order (tenants.sort_order, rdb 0051).
     On a phone TopBarTenant is the switcher and this one is not shown. -->
<template>
  <div class="tenant-drop">
    <div ref="tenantSwitcherEl" class="tenant-switcher" data-testid="tenant-switcher" :title="tenantHintText">
      <span class="tenant-switcher__icon"><UiIcon name="building" :size="16" /></span>
      <span
        class="tenant-switcher__field"
        data-testid="tenant-switcher-box"
        :style="{ gap: (TENANT_ARROW_GAP_PX - TENANT_TEXT_PAD_PX) + 'px' }"
        @mousedown="onTenantBoxPress"
      >
      <select
        ref="tenantSelectEl"
        class="tenant-switcher__select"
        data-testid="tenant-switcher-select"
        :value="tenantBox.selected"
        :aria-label="t('sidebar.tenant')"
        aria-describedby="tenant-switcher-hint"
        :aria-busy="switching ? 'true' : undefined"
        :style="tenantSelectStyle"
        @change="onTenantChange"
      >
        <option v-for="o in tenantBox.options" :key="o.id" :value="o.id">{{ o.label || t('sidebar.tenant') }}</option>
      </select>
      <svg
        class="tenant-switcher__arrow"
        data-testid="tenant-switcher-arrow"
        viewBox="0 0 8 6"
        aria-hidden="true"
        focusable="false"
      >
        <path d="M0 0 H8 L4 6 Z" />
      </svg>
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
import { measureControlText, TENANT_ARROW_GAP_PX, TENANT_TEXT_PAD_PX, tenantDrawnLabels, tenantHint, tenantSwitchOptions, widestLabelWidth } from '~/utils/tenant-switcher.mjs'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const api = useSpoolApi()
const tenantBox = computed(() => tenantSwitchOptions(session.claims, api.tenant))
const tenantHintText = computed(() => tenantHint(tenantBox.value, t))
const tenantSelectEl = ref<HTMLSelectElement | null>(null)
const tenantSwitcherEl = ref<HTMLElement | null>(null)
const tenantTextPx = ref(0)
const tenantSelectStyle = computed(() => {
  const text = tenantTextPx.value
  if (!(text > 0)) return undefined
  return { width: (text + 2 * TENANT_TEXT_PAD_PX) + 'px', paddingInline: TENANT_TEXT_PAD_PX + 'px' }
})
/* The select is only as wide as the widest option in its own font. The arrow
   is the next flex item, TENANT_ARROW_GAP_PX after that edge, so a clamped
   bar cannot slide the arrow back over the name. Re-measured when the list,
   the font-size setting (html data-font-size), or the viewport changes. */
function applyTenantSelectWidth() {
  const sel = tenantSelectEl.value
  if (!sel) return
  const labels = tenantDrawnLabels(tenantBox.value.options, t('sidebar.tenant'))
  const text = widestLabelWidth(labels, (label) => measureControlText(sel, label))
  if (labels.some((label) => label.length > 0) && !(text > 0)) return
  if (Math.abs(tenantTextPx.value - text) > 0.01) tenantTextPx.value = text
}
watch(
  () => tenantDrawnLabels(tenantBox.value.options, t('sidebar.tenant')).join('\n'),
  async () => {
    await nextTick()
    applyTenantSelectWidth()
  },
)
let tenantWidthMq: MediaQueryList | null = null
let tenantFontObs: MutationObserver | null = null
function onTenantWidthViewport() { applyTenantSelectWidth() }
onMounted(() => {
  applyTenantSelectWidth()
  const doc = tenantSwitcherEl.value?.ownerDocument
  const view = doc?.defaultView
  if (doc?.documentElement && typeof MutationObserver === 'function') {
    tenantFontObs = new MutationObserver(() => applyTenantSelectWidth())
    tenantFontObs.observe(doc.documentElement, { attributes: true, attributeFilter: ['data-font-size'] })
  }
  if (!view) return
  tenantWidthMq = view.matchMedia('(max-width: 820px)')
  tenantWidthMq.addEventListener('change', onTenantWidthViewport)
})
onBeforeUnmount(() => {
  tenantFontObs?.disconnect()
  tenantWidthMq?.removeEventListener('change', onTenantWidthViewport)
})
/* SPL-71: the arrow and the box's padding are part of the drop box, so a
   press there opens the list as a press on the name does. */
function onTenantBoxPress(ev: MouseEvent) {
  const sel = tenantSelectEl.value
  if (!sel || ev.button !== 0 || ev.target === sel || sel.contains(ev.target as Node)) return
  ev.preventDefault()
  sel.focus()
  try {
    (sel as HTMLSelectElement & { showPicker?: () => void }).showPicker?.()
  } catch { /* no picker without a user gesture: focus is enough */ }
}
/* specs/026 §6: a member of several tenants switches here (useTenantSwitch,
   shared with the phone top bar's sheet, SPL-995). */
const tenantSwitch = useTenantSwitch()
const switching = tenantSwitch.switching
const switchFailed = tenantSwitch.failed
async function onTenantChange(ev: Event) {
  const el = ev.target
  if (!(el instanceof HTMLSelectElement)) return
  if (!(await tenantSwitch.switchTo(el.value))) el.value = tenantBox.value.selected
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
/* Compact drop box (CLE-34991): one slim row, a glyph and the box, no
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
  appearance: none;
  -webkit-appearance: none;
}
/* The open list. Owner 2026-09-27: 2px more before and after every item
   (SPL-980 had 2px). The rows carry their own theme colours: the select's
   background is transparent, so without them the browser's light popup
   showed the dark theme's light text on white - unreadable. */
.tenant-switcher__select option {
  padding-inline: 4px;
  background-color: var(--color-bg-2);
  color: var(--color-fg);
}
.tenant-switcher__arrow {
  flex: 0 0 auto;
  width: 0.65em;
  height: 0.5em;
  display: block;
  pointer-events: none;
  fill: currentColor;
  color: var(--color-fg);
}
/* SPL-995: on a phone the switcher is TopBarTenant - never shown twice */
@media (max-width: 820px) {
  .tenant-drop { display: none; }
}
</style>
