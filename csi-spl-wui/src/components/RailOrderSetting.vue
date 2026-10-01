<!-- "Left panel order" (SPL-979, Settings → Behaviour): the six left-rail
     icons in the person's order. The same value as dragging the icons in the
     rail itself (useRailOrder over the `rail_order` session claim, kept on the
     hub), so a change in either place shows in the other at once. Reorder by
     dragging a row's grip (mouse or touch) or with the up / down buttons. -->
<template>
  <div v-if="signedIn" class="rail-order" data-test="rail-order-setting">
    <span :id="labelId" class="rail-order__label">{{ t('settings.rail_order.label') }}</span>
    <p :id="hintId" class="muted rail-order__hint">{{ t('settings.rail_order.hint') }}</p>
    <ol ref="listEl" class="rail-order__list" :aria-labelledby="labelId" :aria-describedby="hintId" data-test="rail-order-list">
      <li
        v-for="(item, i) in rows"
        :key="item.id"
        class="rail-order__row"
        :class="{ 'rail-order__row--dragging': drag.draggingId.value === item.id }"
        :data-reorder-id="item.id"
        :data-test="`rail-order-row-${item.id}`"
      >
        <span
          class="rail-order__grip"
          :title="t('settings.rail_order.drag')"
          aria-hidden="true"
          @pointerdown="drag.down($event, item.id)"
        >
          <UiIcon name="grip" :size="18" />
        </span>
        <UiIcon :name="item.icon" :size="18" />
        <span class="rail-order__name">{{ t(item.labelKey) }}</span>
        <button
          type="button"
          class="icon-btn"
          :disabled="i === 0 || rail.saving.value"
          :aria-label="t('settings.rail_order.up', { name: t(item.labelKey) })"
          :title="t('settings.rail_order.up', { name: t(item.labelKey) })"
          :data-test="`rail-order-up-${item.id}`"
          @click="step(item.id, -1)"
        >
          <UiIcon name="chevron-up" :size="18" />
        </button>
        <button
          type="button"
          class="icon-btn"
          :disabled="i === rows.length - 1 || rail.saving.value"
          :aria-label="t('settings.rail_order.down', { name: t(item.labelKey) })"
          :title="t('settings.rail_order.down', { name: t(item.labelKey) })"
          :data-test="`rail-order-down-${item.id}`"
          @click="step(item.id, 1)"
        >
          <UiIcon name="chevron-down" :size="18" />
        </button>
      </li>
    </ol>
    <div class="rail-order__actions">
      <button type="button" class="btn ghost" :disabled="!rail.custom.value || rail.saving.value" data-test="rail-order-reset" @click="store(null)">
        {{ t('settings.rail_order.reset') }}
      </button>
    </div>
    <p class="sr-only" role="status" aria-live="polite">{{ announce }}</p>
    <p v-if="status" class="rail-order__status" role="alert" data-test="rail-order-status">{{ status }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useAuthCopy } from '~/composables/useAuthCopy'
import { useRailOrder } from '~/composables/useRailOrder'
import { useDragReorder } from '~/composables/useDragReorder'
import { RAIL_TABS, moveBy, railLabelKey, type RailId } from '~/utils/rail-order.mjs'
import { useMobileStack } from '~/composables/useMobileStack'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const copy = useAuthCopy()
const rail = useRailOrder()

const labelId = useId()
const hintId = useId()
const listEl = ref<HTMLElement | null>(null)
const signedIn = computed(() => session.state === 'in')
const status = ref('')
const announce = ref('')

const drag = useDragReorder<RailId>({
  order: () => rail.order.value,
  items: () => [...(listEl.value?.querySelectorAll<HTMLElement>('[data-reorder-id]') || [])],
  onDrop: (next) => { void store(next) },
})
const BY_ID = new Map(RAIL_TABS.map((item) => [item.id, item]))
const mobileStack = useMobileStack()
/* CLE-77904: a tab's name as the rail shows it ("Messages" on a phone) */
const rows = computed(() => (drag.preview.value || rail.order.value)
  .map((id) => BY_ID.get(id))
  .filter((item): item is (typeof RAIL_TABS)[number] => Boolean(item))
  .map((item) => ({ ...item, labelKey: railLabelKey(item, mobileStack.isMobile.value) })))

async function store(next: string[] | null) {
  status.value = ''
  const res = await rail.save(next)
  if (!res.ok) {
    status.value = copy.nativeError((res.out ?? null) as Parameters<typeof copy.nativeError>[0]) || t('settings.language.failed')
  }
  return res.ok
}

async function step(id: RailId, delta: number) {
  const ok = await store(moveBy(rail.order.value, id, delta))
  if (!ok) return
  const at = rail.order.value.indexOf(id)
  const item = BY_ID.get(id)
  announce.value = t('settings.rail_order.moved', { name: item ? t(railLabelKey(item, mobileStack.isMobile.value)) : id, n: at + 1 })
  /* the button that was pressed may now be disabled (it reached an end):
     keep the keyboard on the same row */
  await nextTick()
  const sel = `[data-test=rail-order-${delta < 0 ? 'up' : 'down'}-${id}]`
  const btn = listEl.value?.querySelector<HTMLButtonElement>(sel)
  const other = listEl.value?.querySelector<HTMLButtonElement>(`[data-test=rail-order-${delta < 0 ? 'down' : 'up'}-${id}]`)
  ;(btn && !btn.disabled ? btn : other)?.focus()
}

onMounted(() => { if (session.state === 'loading') void session.probe() })
</script>

<style scoped>
.rail-order {
  display: grid;
  gap: 6px;
  min-width: 0;
  max-width: 100%;
}
.rail-order__label { font-weight: 600; }
.rail-order__hint,
.rail-order__status {
  margin: 0;
  overflow-wrap: anywhere;
}
.rail-order__status { color: var(--color-error); }
.rail-order__list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  gap: 4px;
  max-width: 28rem;
}
.rail-order__row {
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
.rail-order__row--dragging { background: var(--color-surface-hover); }
.rail-order__grip {
  display: grid;
  place-items: center;
  min-width: 32px;
  min-height: var(--tap, 44px);
  cursor: grab;
  touch-action: none;
  color: var(--color-muted);
}
.rail-order__row--dragging .rail-order__grip { cursor: grabbing; }
.rail-order__name {
  flex: 1;
  min-width: 0;
  overflow-wrap: anywhere;
}
.rail-order__actions { display: flex; }
/* SPL-993: on a touch screen the grip and the up / down buttons are 44 px
   targets (the rail itself does not drag on a phone - spec 043 D6 - so this
   list is where a phone reorders). */
@media (max-width: 820px) {
  .rail-order__grip { min-width: var(--tap, 44px); }
  .rail-order__row .icon-btn { width: var(--tap, 44px); height: var(--tap, 44px); }
}
</style>
