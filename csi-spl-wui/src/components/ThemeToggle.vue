<!-- Theme picker (was the GRK-3374 sun/moon toggle). A painter's
     palette icon button opens a listbox of the five themes (THEMES in
     utils/theme.mjs), the current one checked; each option shows its own
     theme's background + accent swatch. Choosing persists as before
     (localStorage 'spool-theme', html[data-theme]).
     Keyboard: Enter/Space/ArrowDown open on the current theme, ArrowUp too;
     ArrowUp/Down wrap, Home/End jump; Enter/Space choose, close and return
     focus to the button; Escape closes back to the button; Tab or a click
     outside closes. Accessible name on aria-label + title. -->
<template>
  <div ref="root" class="theme-picker" data-test="theme-picker-root">
    <button
      ref="trigger"
      type="button"
      class="icon-btn theme-toggle"
      data-test="theme-picker"
      aria-haspopup="listbox"
      :aria-expanded="open ? 'true' : 'false'"
      :aria-controls="listId"
      :aria-label="label"
      :title="label"
      @click="toggleOpen"
      @keydown="onTriggerKey"
    >
      <UiIcon name="palette" :size="18" />
    </button>
    <ul
      v-show="open"
      :id="listId"
      role="listbox"
      class="theme-picker__list"
      :class="{ 'theme-picker__list--end': align === 'end' }"
      data-test="theme-picker-list"
      :aria-label="label"
      @keydown="onListKey"
    >
      <li
        v-for="(opt, i) in THEMES"
        :key="opt.id"
        :ref="(el) => { options[i] = el as HTMLElement | null }"
        role="option"
        tabindex="-1"
        class="theme-picker__option"
        :data-test="'theme-option-' + opt.id"
        :data-theme-id="opt.id"
        :aria-selected="opt.id === theme ? 'true' : 'false'"
        @click="choose(opt.id)"
      >
        <span class="theme-picker__swatch" :class="'theme-picker__swatch--' + opt.id" aria-hidden="true" />
        <span class="theme-picker__name">{{ t(opt.labelKey) }}</span>
        <UiIcon v-if="opt.id === theme" class="theme-picker__check" name="check" :size="16" />
      </li>
    </ul>
  </div>
</template>

<script setup lang="ts">
import { useTheme } from '~/composables/useTheme'
import { THEMES, saveThemeToAccount, themeIndex, type SpoolTheme } from '~/utils/theme.mjs'
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { nextMenuIndex } from '~/utils/user-menu.mjs'
import { applyPopover, focusWithoutScroll, readViewport } from '~/utils/place-popover.mjs'

// 'end': the list opens leftwards from the button's end edge (a picker at
// the right of a row, Settings → Appearance), so it stays on a phone screen.
const props = withDefaults(defineProps<{ align?: 'start' | 'end' }>(), { align: 'start' })
const { align } = toRefs(props)
const { theme, setTheme } = useTheme()
const session = useSessionStore()
const auth = useAuthClient()
const { t } = useI18n({ useScope: 'global' })
const label = computed(() => t('theme.picker'))
// Two pickers can be on one page (top bar + Settings → Appearance).
const listId = `theme-picker-list-${useId()}`

const open = ref(false)
const focused = ref(-1)
const root = ref<HTMLElement | null>(null)
const trigger = ref<HTMLButtonElement | null>(null)
const options: (HTMLElement | null)[] = []

function placeList() {
  const panel = root.value?.querySelector<HTMLElement>('.theme-picker__list')
  const btn = trigger.value
  if (!panel || !btn) return
  const r = btn.getBoundingClientRect()
  applyPopover(panel, {
    left: r.left,
    right: r.right,
    top: r.top,
    bottom: r.bottom,
    align: align.value === 'end' ? 'end' : 'start',
    gap: 6,
  }, readViewport())
}

async function focusOption(i: number) {
  focused.value = i
  await nextTick()
  placeList()
  focusWithoutScroll(options[i])
}

function openAt(i: number) {
  open.value = true
  void focusOption(i)
}

function close(refocus: boolean) {
  open.value = false
  focused.value = -1
  if (refocus) focusWithoutScroll(trigger.value)
}

function toggleOpen() {
  if (open.value) close(false)
  else openAt(themeIndex(theme.value))
}

function choose(id: SpoolTheme) {
  setTheme(id)
  close(true)
  // the account keeps it too (signed in only; failure is silent)
  void saveThemeToAccount(id, {
    claims: session.claims,
    save: (t) => auth.saveTheme(t),
    apply: (t) => session.setPreferredTheme(t),
  })
}

function onTriggerKey(e: KeyboardEvent) {
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault()
    openAt(themeIndex(theme.value))
  } else if (e.key === 'Escape' && open.value) {
    e.preventDefault()
    close(true)
  }
}

function onListKey(e: KeyboardEvent) {
  if (e.key === 'Enter' || e.key === ' ') {
    e.preventDefault()
    const opt = THEMES[focused.value]
    if (opt) choose(opt.id)
    return
  }
  const next = nextMenuIndex(focused.value, e.key, THEMES.length)
  if (next === -1) {
    if (e.key === 'Escape') { e.preventDefault(); close(true) } else close(false)
    return
  }
  if (next !== focused.value) {
    e.preventDefault()
    void focusOption(next)
  }
}

function onDocPointer(e: PointerEvent) {
  if (open.value && root.value && !root.value.contains(e.target as Node)) close(false)
}

onMounted(() => document.addEventListener('pointerdown', onDocPointer))
onBeforeUnmount(() => document.removeEventListener('pointerdown', onDocPointer))
</script>

<style scoped>
.theme-picker {
  position: relative;
  display: inline-flex;
  align-items: center;
}
.theme-picker__list {
  position: absolute;
  top: calc(100% + 6px);
  inset-inline-start: 0;
  width: 220px;
  margin: 0;
  padding: 6px 0;
  list-style: none;
  background: var(--color-bg-2);
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-md, 12px);
  box-shadow: 0 12px 32px rgb(0 0 0 / .35);
  z-index: var(--z-overlay, 1000);
}
.theme-picker__list--end {
  inset-inline-start: auto;
  inset-inline-end: 0;
}
.theme-picker__option {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: var(--tap, 44px);
  padding: 0 14px;
  border-radius: var(--radius-sm);
  color: var(--color-fg);
  font-size: 0.875rem;
  cursor: pointer;
}
.theme-picker__option:hover,
.theme-picker__option:focus { background: var(--color-surface-hover); }
.theme-picker__option[aria-selected='true'] { font-weight: 600; }
.theme-picker__swatch {
  flex-shrink: 0;
  width: 20px;
  height: 20px;
  border-radius: 50%;
  border: 1px solid var(--color-border-strong);
}
/* Each option previews its OWN theme (its --color-bg / --color-accent), so
   these are literals, not tokens; a class, never a style attribute (the
   deployed CSP hashes styles). Kept equal to THEMES[].swatch by
   tests/unit/theme-toggle.test.mjs. */
.theme-picker__swatch--dark { background: linear-gradient(135deg, #060912 50%, #34d5f0 50%); }
.theme-picker__swatch--light { background: linear-gradient(135deg, #eaf1fb 50%, #0a97c4 50%); }
.theme-picker__swatch--light-violet { background: linear-gradient(135deg, #f1ecfb 50%, #6a3fd0 50%); }
.theme-picker__swatch--light-green { background: linear-gradient(135deg, #eaf5ee 50%, #16733f 50%); }
.theme-picker__swatch--light-yellow { background: linear-gradient(135deg, #fbf6e3 50%, #855400 50%); }
.theme-picker__swatch--light-orange { background: linear-gradient(135deg, #fbf3ea 50%, #a34b00 50%); }
.theme-picker__swatch--light-red { background: linear-gradient(135deg, #fbeeee 50%, #9a3d58 50%); }
.theme-picker__name { flex: 1; min-width: 0; overflow-wrap: anywhere; }
.theme-picker__check { color: var(--color-accent); flex-shrink: 0; }
/* SPL-990: phones (the avatar sheet, Settings): a 44 px target */
@media (max-width: 820px) {
  .theme-toggle { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
}
</style>
