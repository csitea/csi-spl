<!-- SPL-995 (<= 820 px): the tenant switcher in the phone top bar. A bordered
     drop box (the sidebar's SPL-71 look: the name, then the arrow) that is a
     44 px target; a long name ends in an ellipsis. A press opens a bottom
     sheet over a scrim listing the tenants; picking another one switches
     (useTenantSwitch, specs/026 §6). Above 820 px TopBar hides it and the
     sidebar's drop box is the switcher. -->
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
    <template v-if="open">
      <div class="tb-tenant__scrim" data-testid="top-bar-tenant-scrim" aria-hidden="true" @click="close(true)" />
      <div
        class="tb-tenant__sheet"
        data-testid="top-bar-tenant-sheet"
        role="dialog"
        aria-modal="true"
        :aria-label="t('sidebar.tenant')"
        @keydown.esc.prevent="close(true)"
      >
        <span class="tb-tenant__grip" aria-hidden="true" />
        <p class="tb-tenant__hint">{{ ts.hint.value }}</p>
        <ul class="tb-tenant__list" role="listbox" :aria-label="t('sidebar.tenant')">
          <li v-for="o in rows" :key="o.id" role="none">
            <button
              type="button"
              role="option"
              class="tb-tenant__row"
              data-testid="top-bar-tenant-option"
              :data-tenant="o.id"
              :aria-selected="o.id === ts.box.value.selected ? 'true' : 'false'"
              :disabled="ts.switching.value"
              @click="pick(o.id)"
            >
              <span class="tb-tenant__row-name">{{ o.label || o.id }}</span>
              <UiIcon v-if="o.id === ts.box.value.selected" name="check" :size="18" />
            </button>
          </li>
        </ul>
        <p v-if="ts.failed.value" class="tb-tenant__error" role="alert" data-testid="top-bar-tenant-error">{{ t('sidebar.tenant_switch_failed') }}</p>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useTenantSwitch } from '~/composables/useTenantSwitch'
import { useMobileStack } from '~/composables/useMobileStack'
import { focusWithoutScroll } from '~/utils/place-popover.mjs'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const ts = useTenantSwitch()
const open = ref(false)
const trigger = ref<HTMLButtonElement | null>(null)
/* the placeholder row (no active tenant named yet) is not a choice */
const rows = computed(() => ts.box.value.options.filter((o: { id: string }) => o.id))

async function openSheet() {
  open.value = true
  await nextTick()
  const sel = document.querySelector<HTMLElement>('[data-testid=top-bar-tenant-option][aria-selected=true]')
    || document.querySelector<HTMLElement>('[data-testid=top-bar-tenant-option]')
  focusWithoutScroll(sel)
}
function close(refocus: boolean) {
  open.value = false
  if (refocus) focusWithoutScroll(trigger.value)
}
function toggle() {
  if (open.value) close(false)
  else void openSheet()
}
async function pick(id: string) {
  if (id === ts.box.value.selected) {
    close(true)
    return
  }
  /* a switch reloads the page; a refusal keeps the sheet open with the error */
  await ts.switchTo(id)
}
watch(() => route.fullPath, () => { if (open.value) close(false) })
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
.tb-tenant__scrim {
  position: fixed;
  inset: 0;
  z-index: var(--z-overlay, 1000);
  background: rgb(0 0 0 / .45);
}
.tb-tenant__sheet {
  position: fixed;
  inset-inline: 0;
  bottom: 0;
  z-index: calc(var(--z-overlay, 1000) + 1);
  max-height: 85dvh;
  overflow-y: auto;
  overscroll-behavior: contain;
  box-sizing: border-box;
  padding: 6px 0 calc(8px + env(safe-area-inset-bottom, 0px));
  background: var(--color-bg-2);
  border: 1px solid var(--color-border-strong);
  border-bottom: 0;
  border-radius: var(--radius-md, 12px) var(--radius-md, 12px) 0 0;
  box-shadow: 0 -12px 32px rgb(0 0 0 / .35);
}
.tb-tenant__grip {
  display: block;
  width: 36px;
  height: 4px;
  margin: 2px auto 6px;
  border-radius: var(--radius-pill, 999px);
  background: var(--color-border-strong);
}
.tb-tenant__hint {
  margin: 0;
  padding: 4px 14px 8px;
  font-size: 0.8125rem;
  color: var(--color-muted);
  border-bottom: 1px solid var(--color-border);
}
.tb-tenant__list { list-style: none; margin: 6px 0 0; padding: 0; }
.tb-tenant__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  width: 100%;
  min-height: 48px;
  padding: 0 14px;
  border: 0;
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  font-size: 0.9375rem;
  text-align: start;
  cursor: pointer;
}
.tb-tenant__row[aria-selected=true] { font-weight: 700; color: var(--color-accent); }
.tb-tenant__row:hover, .tb-tenant__row:focus-visible { background: var(--color-surface-hover); }
.tb-tenant__row-name { min-width: 0; overflow-wrap: anywhere; }
.tb-tenant__error {
  margin: 6px 14px 0;
  font-size: 0.8125rem;
  color: var(--color-danger);
}
</style>
