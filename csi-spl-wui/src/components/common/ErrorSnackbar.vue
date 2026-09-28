<!-- Sliding top error snackbar (topic 4335f075).

     Renders the queue in utils/error-snackbar.mjs — one source, the journal
     (subscribe via bindSnackbarToJournal). Newest on top, at most 3, count
     badge for coalesced repeats. About the top-bar height; slides in from
     the top; prefers-reduced-motion drops the slide. -->
<template>
  <div
    v-if="items.length"
    class="error-snackbar"
    role="region"
    :aria-label="t('snackbar.region')"
    data-test="error-snackbar"
  >
    <div
      v-for="item in items"
      :key="item.id"
      class="error-snackbar__item"
      role="alert"
      data-test="error-snackbar-item"
      :data-id="item.id"
      @pointerenter="hold(item.id, true)"
      @pointerleave="hold(item.id, false)"
      @focusin="hold(item.id, true)"
      @focusout="hold(item.id, false)"
    >
      <UiIcon class="error-snackbar__icon" name="alert-triangle" :size="18" />
      <div class="error-snackbar__body">
        <p class="error-snackbar__text">{{ item.text }}</p>
        <p v-if="item.errorId" class="error-snackbar__id" dir="ltr">{{ item.errorId }}</p>
      </div>
      <span
        v-if="item.count > 1"
        class="error-snackbar__count"
        data-test="error-snackbar-count"
      >{{ t('snackbar.repeat', { n: item.count }) }}</span>
      <button
        type="button"
        class="icon-btn error-snackbar__dismiss"
        data-test="error-snackbar-dismiss"
        :aria-label="t('snackbar.dismiss')"
        :title="t('snackbar.dismiss')"
        @click="queue.dismiss(item.id)"
      >
        <UiIcon name="x" :size="16" />
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
import UiIcon from '@/components/UiIcon.vue'
import { getErrors, subscribeErrors } from '@/composables/errorJournal.mjs'
import {
  SNACKBAR_TICK_MS,
  bindSnackbarToJournal,
  createSnackbarQueue,
} from '~/utils/error-snackbar.mjs'

type SnackItem = {
  id: string
  errorId: string
  text: string
  source: string
  status: number
  count: number
  at: string
  expiresAt: number
  held: boolean
}

const { t } = useI18n({ useScope: 'global' })
const queue = createSnackbarQueue()
const items = shallowRef<SnackItem[]>([])

function hold(id: string, on: boolean) {
  queue.hold(id, on)
}

onMounted(() => {
  const unsub = queue.subscribe((next) => {
    items.value = next as SnackItem[]
  })
  items.value = queue.items() as SnackItem[]
  const unbind = bindSnackbarToJournal(queue, { getErrors, subscribeErrors })
  const tick = setInterval(() => { queue.tick() }, SNACKBAR_TICK_MS)
  onBeforeUnmount(() => {
    unsub()
    unbind()
    clearInterval(tick)
  })
})
</script>

<style scoped>
.error-snackbar {
  position: fixed;
  top: 0;
  left: 50%;
  transform: translateX(-50%);
  z-index: var(--z-snackbar);
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  width: min(36rem, calc(100vw - 2rem));
  padding: 0.5rem;
  pointer-events: none;
}
.error-snackbar__item {
  pointer-events: auto;
  display: flex;
  align-items: center;
  gap: 0.5rem;
  min-height: var(--top-bar-h);
  padding: 0.5rem 0.75rem;
  border: 1px solid var(--color-danger);
  border-radius: var(--radius-sm);
  background: color-mix(in srgb, var(--color-danger) 12%, var(--color-surface));
  color: var(--color-fg);
  box-shadow: var(--focus-3d);
  animation: error-snackbar-in 0.28s ease-out;
}
.error-snackbar__icon { flex: none; color: var(--color-danger); }
.error-snackbar__body { min-width: 0; flex: 1 1 auto; }
.error-snackbar__text {
  margin: 0;
  font-size: 0.875rem;
  overflow-wrap: anywhere;
}
.error-snackbar__id {
  margin: 0.15rem 0 0;
  font-family: var(--font-mono);
  font-size: 0.75rem;
  opacity: 0.85;
  overflow-wrap: anywhere;
}
.error-snackbar__count {
  flex: none;
  font-size: 0.75rem;
  font-weight: 600;
  padding: 0.1rem 0.4rem;
  border-radius: var(--radius-pill);
  background: color-mix(in srgb, var(--color-fg) 10%, transparent);
}
.error-snackbar__dismiss:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}
@keyframes error-snackbar-in {
  from { transform: translateY(-100%); opacity: 0; }
  to { transform: translateY(0); opacity: 1; }
}
@media (prefers-reduced-motion: reduce) {
  .error-snackbar__item { animation: none; }
}
</style>
