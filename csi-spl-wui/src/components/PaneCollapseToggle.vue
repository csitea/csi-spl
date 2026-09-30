<!-- Spec 050 (owner, prd t1 topic d2c03bc9): the small triangle at the BOTTOM
     corner of a vertical panel that collapses it to a thin strip and expands it
     back. One per panel (channels, topic, threads). It is a real
     <button aria-expanded> so Tab + Enter/Space reach it; there is no keyboard
     shortcut (owner Q7). The corner side follows the Win/Mac close_buttons rule
     (mac = start/left, windows = end/right, SPL-1133). The glyph points the way
     the panel will MOVE when clicked (owner, prd t1 topic 80e40aca): toward the
     edge it collapses to while open, back toward where it expands while
     collapsed — ONE shared rule (utils/pane-collapse.mjs arrowPointsEnd), so the
     left panel points ◀ open, the right panel ▶ open, and the middle follows its
     toggle corner. RTL mirrors it for free via CSS logical borders. The triangle
     is drawn with CSS borders (no shared-icon dependency). -->
<template>
  <button
    type="button"
    class="pane-collapse"
    :class="[`pane-collapse--${side}`, { 'pane-collapse--collapsed': collapsed, 'pane-collapse--point-end': pointsEnd, 'pane-collapse--point-start': !pointsEnd }]"
    :data-test="`pane-collapse-${pane}`"
    :data-pane="pane"
    :data-collapse-side="side"
    :aria-expanded="collapsed ? 'false' : 'true'"
    :aria-label="label"
    :title="label"
    @click="store.toggle(pane)"
  >
    <span class="pane-collapse__tri" aria-hidden="true" />
  </button>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useSessionStore } from '~/stores/session'
import { usePaneCollapse, type PaneName } from '~/stores/pane-collapse'
import { arrowPointsEnd, collapseSide } from '~/utils/pane-collapse.mjs'

const props = defineProps<{ pane: PaneName }>()
const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const store = usePaneCollapse()

const collapsed = computed(() => store.collapsed[props.pane])
const side = computed(() => collapseSide(session.claims?.close_buttons))
/* the arrow points the way this panel will move when clicked (owner topic
   80e40aca) — one shared rule for all three panes, RTL-mirrored by CSS */
const pointsEnd = computed(() => arrowPointsEnd(collapsed.value, props.pane, side.value))

/* per-panel aria label; the owner's terms (channels / messages / thread) */
const NOUN: Record<PaneName, string> = { channels: 'channels', topic: 'messages', threads: 'thread' }
const label = computed(() =>
  collapsed.value
    ? t(`pane.expand_${NOUN[props.pane]}`)
    : t(`pane.collapse_${NOUN[props.pane]}`),
)
</script>
