<!-- "Channel order" (owner DM 7fa9656f: "the same option should apply to the
     order of the channels as well", Settings → Behaviour): the Channels list
     of this workspace in the person's order, beside "Left panel order". The
     same value as dragging a channel row or its Move up / Move down in the
     left panel (useChannelOrder over PUT /v1/me/channel-order, SPL-1034, kept
     per person and per workspace on the hub), so a change in either place
     shows in the other at once. Reorder by dragging a row's grip (mouse or
     touch) or with the up / down buttons. -->
<template>
  <div v-if="signedIn" class="channel-order" data-test="channel-order-setting">
    <span :id="labelId" class="channel-order__label">{{ t('settings.channel_order.label') }}</span>
    <p :id="hintId" class="muted channel-order__hint">{{ t('settings.channel_order.hint') }}</p>
    <p v-if="!rows.length" class="muted channel-order__hint" data-test="channel-order-empty">{{ t('settings.channel_order.empty') }}</p>
    <ol v-else ref="listEl" class="channel-order__list" :aria-labelledby="labelId" :aria-describedby="hintId" data-test="channel-order-list">
      <li
        v-for="(item, i) in rows"
        :key="item.id"
        class="channel-order__row"
        :class="{ 'channel-order__row--dragging': drag.draggingId.value === item.id }"
        :data-reorder-id="item.id"
        :data-test="`channel-order-row-${item.id}`"
      >
        <span
          class="channel-order__grip"
          :title="t('settings.rail_order.drag')"
          aria-hidden="true"
          @pointerdown="drag.down($event, item.id)"
        >
          <UiIcon name="grip" :size="18" />
        </span>
        <span class="channel-order__name"># {{ item.name }}</span>
        <button
          type="button"
          class="icon-btn"
          :disabled="i === 0"
          :aria-label="t('settings.rail_order.up', { name: item.name })"
          :title="t('settings.rail_order.up', { name: item.name })"
          :data-test="`channel-order-up-${item.id}`"
          @click="step(item.id, -1)"
        >
          <UiIcon name="chevron-up" :size="18" />
        </button>
        <button
          type="button"
          class="icon-btn"
          :disabled="i === rows.length - 1"
          :aria-label="t('settings.rail_order.down', { name: item.name })"
          :title="t('settings.rail_order.down', { name: item.name })"
          :data-test="`channel-order-down-${item.id}`"
          @click="step(item.id, 1)"
        >
          <UiIcon name="chevron-down" :size="18" />
        </button>
      </li>
    </ol>
    <div class="channel-order__actions">
      <button type="button" class="btn ghost" :disabled="!channelOrder.order.value.length" data-test="channel-order-reset" @click="channelOrder.reset()">
        {{ t('settings.rail_order.reset') }}
      </button>
    </div>
    <p class="sr-only" role="status" aria-live="polite">{{ announce }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useChannelStore } from '~/stores/channel'
import { useChannelOrder } from '~/composables/useChannelOrder'
import { useDragReorder } from '~/composables/useDragReorder'
import { pinRows } from '~/utils/sidebar-row-menu.mjs'
import { feedbackChannelCopy } from '~/utils/feedback-channel.mjs'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const channel = useChannelStore()
const channelOrder = useChannelOrder()

const labelId = useId()
const hintId = useId()
const listEl = ref<HTMLElement | null>(null)
const signedIn = computed(() => session.state === 'in')
const announce = ref('')

/* the rows the left panel draws, in the same order (ChannelSidebar channelRows) */
const shown = computed(() => pinRows(
  channel.ordered,
  channelOrder.order.value,
  (c: { channel_id?: string }) => String(c.channel_id || ''),
).map((c: { channel_id?: string, name?: string, description?: string }) => {
  const id = String(c.channel_id || '')
  const copy = feedbackChannelCopy(id, {
    name: t('channels.feedback.name'),
    description: t('channels.feedback.description'),
  }, c.description)
  return { id, name: String((copy && copy.name) || c.name || id) }
}).filter((c: { id: string }) => c.id))
const displayed = computed(() => shown.value.map((c) => c.id))

const drag = useDragReorder<string>({
  order: () => displayed.value,
  items: () => [...(listEl.value?.querySelectorAll<HTMLElement>('[data-reorder-id]') || [])],
  onDrop: (next) => { void channelOrder.set(next) },
})
const BY_ID = computed(() => new Map(shown.value.map((c) => [c.id, c])))
const rows = computed(() => (drag.preview.value || displayed.value)
  .map((id) => BY_ID.value.get(id))
  .filter((c): c is { id: string, name: string } => Boolean(c)))

async function step(id: string, delta: -1 | 1) {
  await channelOrder.step(displayed.value, id, delta)
  const at = displayed.value.indexOf(id)
  announce.value = t('settings.rail_order.moved', { name: BY_ID.value.get(id)?.name || id, n: at + 1 })
  /* the button that was pressed may now be disabled (it reached an end):
     keep the keyboard on the same row */
  await nextTick()
  const sel = `[data-test=channel-order-${delta < 0 ? 'up' : 'down'}-${id}]`
  const btn = listEl.value?.querySelector<HTMLButtonElement>(sel)
  const other = listEl.value?.querySelector<HTMLButtonElement>(`[data-test=channel-order-${delta < 0 ? 'down' : 'up'}-${id}]`)
  ;(btn && !btn.disabled ? btn : other)?.focus()
}

onMounted(() => { if (session.state === 'loading') void session.probe() })
</script>

<style scoped>
.channel-order {
  display: grid;
  gap: 6px;
  min-width: 0;
  max-width: 100%;
}
.channel-order__label { font-weight: 600; }
.channel-order__hint {
  margin: 0;
  overflow-wrap: anywhere;
}
.channel-order__list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  gap: 4px;
  max-width: 28rem;
}
.channel-order__row {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: var(--tap, 44px);
  min-width: 0;
  padding-inline: 4px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
}
.channel-order__row--dragging { background: var(--color-surface-hover); }
.channel-order__grip {
  display: grid;
  place-items: center;
  min-width: 32px;
  min-height: var(--tap, 44px);
  cursor: grab;
  touch-action: none;
  color: var(--color-muted);
}
.channel-order__row--dragging .channel-order__grip { cursor: grabbing; }
.channel-order__name {
  flex: 1;
  min-width: 0;
  overflow-wrap: anywhere;
}
.channel-order__actions { display: flex; }
/* as "Left panel order" (SPL-993): 44 px grip and buttons on a touch screen,
   where this list is where a phone drags (the panel uses the row menu) */
@media (max-width: 820px) {
  .channel-order__grip { min-width: var(--tap, 44px); }
  .channel-order__row .icon-btn { width: var(--tap, 44px); height: var(--tap, 44px); }
}
</style>
