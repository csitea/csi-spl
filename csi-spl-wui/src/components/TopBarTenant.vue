<!-- SPL-995 (<= 820 px): the tenant switcher in the phone top bar. A bordered
     drop box (the sidebar's SPL-71 look: the name, then the arrow) that is a
     44 px target; a long name ends in an ellipsis. A press opens a bottom
     sheet over a scrim listing the tenants; picking another one switches
     (useTenantSwitch, specs/026 §6). Above 820 px TopBar hides it and the
     sidebar's drop box is the switcher.
     SPL-2268: the sheet (TopBarTenantSheet, a lazy chunk loaded on the
     first open) is a keyboard combobox: type to filter, Up/Down/Home/End,
     Enter switches, Esc closes. -->
<template>
  <div class="tb-tenant" data-test="top-bar-tenant" :title="ts.hint.value">
    <button
      ref="trigger"
      type="button"
      class="tb-tenant__box"
      data-testid="top-bar-tenant-box"
      aria-haspopup="dialog"
      :aria-expanded="open ? 'true' : 'false'"
      :aria-label="t('sidebar.tenant') + ': ' + (ts.name.value || t('sidebar.tenant'))"
      :aria-busy="ts.switching.value ? 'true' : undefined"
      @click="toggle"
    >
      <span class="tb-tenant__name" data-testid="top-bar-tenant-name">{{ ts.name.value || t('sidebar.tenant') }}</span>
      <svg class="tb-tenant__arrow" viewBox="0 0 8 6" aria-hidden="true" focusable="false"><path d="M0 0 H8 L4 6 Z" /></svg>
    </button>
    <LazyTopBarTenantSheet v-if="open" :ts="ts" @close="close" @pick="pick" />
  </div>
</template>

<script setup lang="ts">
import { useTenantSwitch } from '~/composables/useTenantSwitch'
import { useMobileStack } from '~/composables/useMobileStack'
import { focusWithoutScroll } from '~/utils/place-popover'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const ts = useTenantSwitch()
const open = ref(false)
const trigger = ref<HTMLButtonElement | null>(null)
function close(refocus: boolean) {
  open.value = false
  if (refocus) focusWithoutScroll(trigger.value)
}
function toggle() {
  if (open.value) close(false)
  else open.value = true
}
async function pick(id: string) {
  if (id === ts.box.value.selected) {
    close(true)
    return
  }
  /* a switch reloads the page (the mock re-points the session: the sheet
     closes); a refusal keeps the sheet open with the error.
     SPL-2399 (owner HUM-10 499ef7c4, "tapping it does nothing"): while the
     page is leaving for the new workspace (switching stays true) the sheet
     stays open - closing it pops its history entry (useMobileStack), and
     that history.go(-1) aborts the pending location.assign. */
  if (await ts.switchTo(id) && !ts.switching.value) close(true)
}
watch(() => route.fullPath, () => { if (open.value) close(false) })
/* SPL-2418: a switch that ended without leaving the page (Back restored it
   from the bfcache) closes the sheet it kept open; a refusal keeps it open
   with its error */
watch(ts.switching, (now, was) => { if (was && !now && open.value && !ts.failed.value) close(false) })
/* SPL-994: the sheet is the top level while open - Back closes it first */
useMobileStack().overlay(open, () => close(false))
</script>

<style scoped>
.tb-tenant { display: flex; min-width: 0; }
.tb-tenant__box {
  appearance: none;
  display: inline-flex;
  align-items: center;
  gap: 1px;
  min-width: var(--tap, 44px);
  max-width: 100%;
  min-height: var(--tap, 44px);
  box-sizing: border-box;
  padding: 0 8px;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
  font: inherit;
  font-size: 1rem;
  font-weight: 700;
  cursor: pointer;
}
/* SPL-980: 2px before and after the name, then the arrow after it. Owner
   2026-09-27 (topic 72773b61): the whole control 4 px wider, the extra space
   between the name and the arrow - 2 + 1 + 5 = 8px (was 4px) */
.tb-tenant__name {
  min-width: 0;
  padding-inline: 2px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.tb-tenant__arrow {
  flex: 0 0 auto;
  width: 0.65em;
  height: 0.5em;
  margin-inline-start: 5px;
  fill: currentColor;
}
</style>
