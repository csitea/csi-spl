<!-- The WUI's ONE menu opened AT A POINT (a row's right-click, long-press or
     ... button): icon + name per entry, arrows move, Escape / Tab / a click
     outside close it; a bottom sheet over a dimmed page at <= 820 px
     (SPL-991). The behaviour is usePointMenu's (CLE-77915); this is the
     panel. MessageMenu, SearchRowMenu and IssueRowMenu each carried this
     template and its CSS, copied (CLE-77936); they now only map their
     items and their `choose`.

     `block` keeps each host's own class names (`msg-menu`, `issue-menu`:
     `<block>__item`, `<block>__item--danger`, ...) next to the shared
     `point-menu*` ones the CSS is written on, so every selector the e2e
     suites and proofs read still matches. Test ids: the panel is `testid`,
     an entry `<testid>-<id>`, a locked entry's reason `<testid>-why`; with
     `dataTest` the same shape again as `data-test`. -->
<template>
  <Teleport to="body">
    <SheetBackdrop v-if="open && sheet" @close="emit('close')" />
    <div
      v-if="open"
      ref="root"
      class="point-menu"
      :class="[block, {
        'touch-sheet': sheet,
        'point-menu--wide': wide,
        'point-menu--over-modal': overModal,
        [block + '--over-modal']: overModal,
      }]"
      :data-testid="testid"
      :data-test="dataTest || undefined"
      @keydown="onMenuKey"
      @pointerdown="armed = true"
      @contextmenu.prevent
    >
      <ul role="menu" class="point-menu__items" :class="block + '__items'" :aria-label="label">
        <li v-for="item in items" :key="item.id" role="none">
          <button
            type="button"
            role="menuitem"
            tabindex="-1"
            class="point-menu__item"
            :class="[block + '__item', {
              'point-menu__item--danger': item.danger,
              [block + '__item--danger']: item.danger,
              'point-menu__item--off': item.disabled,
              [block + '__item--off']: item.disabled,
            }]"
            :data-testid="testid + '-' + item.id"
            :data-test="dataTest ? dataTest + '-' + item.id : undefined"
            :data-disabled="item.disabled ? 'true' : undefined"
            :aria-disabled="item.disabled ? 'true' : undefined"
            :aria-describedby="item.disabled && item.hintKey ? hintId + item.id : undefined"
            :title="item.disabled && item.hintKey ? t(item.hintKey) : undefined"
            @click.stop="choose(item.id, item.disabled, $event)"
          >
            <UiIcon :name="item.icon" :size="16" />
            <span class="point-menu__text" :class="block + '__text'">
              <span>{{ t(item.labelKey) }}</span>
              <!-- CLE-77891: a locked entry says why (the tooltip on a desktop;
                   a finger has no hover, so the sheet shows it under the name) -->
              <small
                v-if="item.disabled && item.hintKey"
                :id="hintId + item.id"
                class="point-menu__why"
                :class="[block + '__why', { 'sr-only': !sheet }]"
                :data-testid="testid + '-why'"
              >{{ t(item.hintKey) }}</small>
            </span>
          </button>
        </li>
      </ul>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { usePointMenu } from '~/composables/usePointMenu'
import type { UiIconName } from '~/utils/uiIcons'

export type PointMenuItem = {
  id: string
  icon: UiIconName
  labelKey: string
  /** drawn in the danger colour (Delete) */
  danger?: boolean
  /** CLE-77891: shown, but a click does nothing and keeps the menu open */
  disabled?: boolean
  /** the i18n key of why a disabled entry is locked */
  hintKey?: string
}

const props = defineProps<{
  open: boolean
  x: number
  y: number
  items: PointMenuItem[]
  /** the menu's accessible name (already translated) */
  label: string
  /** the host's class block: `msg-menu`, `issue-menu` */
  block: string
  testid: string
  dataTest?: string
  /** 11rem instead of 10rem (the issue menu's longer names) */
  wide?: boolean
  /** CLE-77806: lift above a modal (a menu opened from a dialog's header) */
  overModal?: boolean
  /** re-place when the point moves while open (the issue sheet's rows) */
  followPoint?: boolean
}>()
const emit = defineEmits<{
  close: []
  escape: []
  choose: [id: string]
}>()
const { t } = useI18n({ useScope: 'global' })
const { root, sheet, onMenuKey } = usePointMenu({
  open: () => props.open, x: () => props.x, y: () => props.y,
  close: () => emit('close'), escape: () => emit('escape'),
  followPoint: props.followPoint,
})
const hintId = useId() + '-why-'

/* A sheet entry acts only on a tap that STARTED in the sheet (SheetBackdrop's
   rule). The finger that long-pressed a card lifts over the sheet that just
   appeared, and a tall sheet (MessageMenu's, t1 7a6be5a3) reaches up under
   it: the lift's click chose the entry there and closed the menu - measured
   at 360x740, the lift at y 167 on Add emoji, the sheet's top at 125. A key
   (Enter / Space) clicks with detail 0 and still chooses. */
const armed = ref(false)
watch(() => props.open, (o) => { if (o) armed.value = false })

/* choose first: the host reads its open row before close clears it */
function choose(id: string, disabled?: boolean, ev?: MouseEvent) {
  if (sheet.value && ev && ev.detail > 0 && !armed.value) return
  /* a disabled entry does nothing and keeps the menu open: its reason stays readable */
  if (disabled) return
  emit('choose', id)
  emit('close')
}
</script>

<style scoped>
.point-menu {
  position: fixed;
  top: 0;
  left: 0;
  visibility: hidden;
  max-height: calc(100dvh - 16px);
  overflow-y: auto;
  overscroll-behavior: contain;
  z-index: var(--z-overlay);
  min-width: 10rem;
  max-width: min(16rem, 70vw);
  background: var(--color-bg-2, var(--color-surface));
  border: 1px solid var(--color-border-strong, var(--color-border));
  border-radius: var(--radius-md);
  box-shadow: 0 12px 32px rgb(0 0 0 / .35);
  padding: 4px 0;
}
.point-menu--wide { min-width: 11rem; }
/* CLE-77806: the desktop popover sits at --z-overlay, below --z-modal */
.point-menu.point-menu--over-modal { z-index: calc(var(--z-modal) + 2); }
.point-menu__items { list-style: none; margin: 0; padding: 0; }
.point-menu__item {
  appearance: none;
  display: flex;
  align-items: center;
  justify-content: flex-start;
  gap: 8px;
  width: 100%;
  text-align: start;
  background: transparent;
  border: 0;
  color: var(--color-fg);
  font: inherit;
  font-size: 0.875rem;
  padding: 8px 12px;
  cursor: pointer;
  min-height: 36px;
}
.point-menu__item .ui-icon { flex: 0 0 auto; }
.point-menu__text { display: flex; flex-direction: column; min-width: 0; }
.point-menu__item--off { color: var(--color-muted); opacity: .7; cursor: not-allowed; }
.point-menu__why { font-size: 0.75rem; line-height: 1.3; white-space: normal; }
.point-menu__item:hover,
.point-menu__item:focus-visible {
  background: var(--color-surface-hover);
  outline: none;
}
.point-menu__item--danger { color: var(--color-danger); }
/* a phone row is a 44 px touch target */
.touch-sheet .point-menu__item { min-height: var(--tap, 44px); }
</style>
