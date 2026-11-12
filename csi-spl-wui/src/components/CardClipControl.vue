<!-- (specs/033 FR-023): the middle pane's card height, three ways -
     titles (the first 90 characters) / 5 rows (default) / full. Native radios
     in one named group, so Tab lands on the group and the arrow keys move
     between the three; the label around each radio is the visible segment.
     One mode per browser for every middle-pane surface (useCardClip).
     SPL-941: each segment is an icon; its words are the tooltip and the
     radio's accessible name. SPL-945: `pane="thread"` is the right pane's
     own control (its own stored mode, applied to the replies). -->
<template>
  <div
    class="card-clip-ctl"
    role="radiogroup"
    :aria-label="t('feed.clip.label')"
    :title="t('feed.clip.label')"
    data-testid="card-clip-control"
    :data-mode="mode"
    :data-clip-pane="pane"
  >
    <label
      v-for="m in CARD_CLIP_MODES"
      :key="m"
      class="card-clip-ctl__opt"
      :class="{ 'card-clip-ctl__opt--on': mode === m }"
      :title="t('feed.clip.mode.' + m)"
    >
      <input
        type="radio"
        :name="name"
        :value="m"
        :checked="mode === m"
        :data-testid="`card-clip-${m}`"
        @change="setMode(m)"
      />
      <UiIcon :name="ICON[m]" size="1em" />
      <span class="sr-only">{{ t('feed.clip.mode.' + m) }}</span>
    </label>
  </div>
</template>

<script setup lang="ts">
import { useCardClip, type CardClipPane } from '~/composables/useCardClip'
import { CARD_CLIP_MODES } from '~/utils/card-clip.mjs'
import type { UiIconName } from '~/utils/uiIcons'

const ICON: Record<string, UiIconName> = { titles: 'clip-titles', rows: 'clip-rows', full: 'clip-full' }

const props = withDefaults(defineProps<{ pane?: CardClipPane }>(), { pane: 'msgs' })
const { t } = useI18n({ useScope: 'global' })
const { mode, setMode } = useCardClip(props.pane)
/* one radio group per control on the page */
const name = `card-clip-${useId()}`
</script>

<style scoped>
/* SPL-5349 (owner HUM-10, t1 2fafde5c: "30% smaller than now ... probably a
   little bit wider"): 70% of the old height, a little wider than 70% -
   cells 26 x 16 px on the desktop (was 33 x 24), 35 x 30 on a phone (was
   44 x 44); the topic priority bar takes the same size */
.card-clip-ctl {
  display: inline-flex;
  flex-shrink: 0;
  margin-inline-start: auto;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
}
.card-clip-ctl__opt {
  position: relative;
  box-sizing: border-box;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 26px;
  height: 16px;
  /* the icon is 1em, so it follows the font size setting */
  font-size: 0.75rem;
  color: var(--color-muted);
  cursor: pointer;
  white-space: nowrap;
}
.card-clip-ctl__opt:first-child { border-start-start-radius: var(--radius-pill); border-end-start-radius: var(--radius-pill); }
.card-clip-ctl__opt:last-child { border-start-end-radius: var(--radius-pill); border-end-end-radius: var(--radius-pill); }
.card-clip-ctl__opt + .card-clip-ctl__opt { border-inline-start: 1px solid var(--color-border); }
.card-clip-ctl__opt--on {
  background: var(--color-selected);
  color: var(--color-fg);
  font-weight: 600;
}
/* the radio stays in the tab order and the accessibility tree, drawn by its label */
.card-clip-ctl__opt input {
  position: absolute;
  inset: 0;
  margin: 0;
  opacity: 0;
  cursor: pointer;
}
.card-clip-ctl__opt:has(input:focus-visible) {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: calc(-1 * var(--focus-ring-w));
}
/* SPL-989: not hover-only (the radio is drawn by its always-visible label);
   on a phone each segment keeps a 44 px tall target: its radio, invisible,
   stands out of the drawn cell */
@media (max-width: 820px) {
  .card-clip-ctl__opt { width: 35px; height: 30px; font-size: 0.875rem; }
  .card-clip-ctl__opt input {
    inset: 50% 0 auto;
    height: var(--tap);
    transform: translateY(-50%);
    appearance: none;
    border-radius: var(--radius-xs);
  }
}
</style>
