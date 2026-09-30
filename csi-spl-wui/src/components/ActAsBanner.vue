<!-- specs/054: the unmissable "Acting as X" banner. Shown on every route while
     THIS session is a temporary act-as clone (access.me.actAs, set by the hub
     on GET /v1/view/me). It is a permanent strip, high z-index, not
     dismissible; its Stop button signs the clone out (owner's rule: a
     sign-out, not a silent switch back) and lands on the login page. Eager,
     never Lazy: it must show the moment the app mounts as a clone. -->
<template>
  <div
    v-if="actAs"
    class="actas-bar"
    role="alert"
    aria-live="assertive"
    data-test="actas-banner"
  >
    <span class="actas-bar__text">{{ t('act_as.acting_as', { name: actAs.targetName }) }}</span>
    <button
      type="button"
      class="btn actas-bar__stop"
      data-test="actas-stop"
      :disabled="busy"
      @click="stop"
    >
      {{ t('act_as.stop') }}
    </button>
  </div>
</template>

<script setup lang="ts">
import { useAccessStore } from '~/stores/access'
import { useSessionStore } from '~/stores/session'

const { t } = useI18n()
const access = useAccessStore()
const session = useSessionStore()
const busy = ref(false)

// Only while signed in: after the sign-out the access store's `me` lingers
// until the next load, so gate on the session so the banner never outlives the
// clone (e.g. on the login page the sign-out lands on).
const actAs = computed(() => (session.state === 'in' ? access.me?.actAs : null) ?? null)

async function stop() {
  if (busy.value) return
  busy.value = true
  try {
    await session.stopActingAs()
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.actas-bar {
  position: fixed;
  /* Directly under the top bar — a full-width, unmistakable strip that never
     covers the avatar menu (whose "Stop acting as X" is the same action). */
  top: var(--top-bar-h);
  left: 0;
  right: 0;
  z-index: calc(var(--z-banner) + 10);
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.75rem;
  box-sizing: border-box;
  padding: 0.375rem 0.875rem;
  border-bottom: 2px solid var(--color-accent);
  /* A warm, unmistakable strip so an admin always knows they are a clone. */
  background: color-mix(in srgb, var(--color-accent) 22%, var(--color-surface));
  color: var(--color-fg);
  box-shadow: var(--focus-3d);
  font-size: 0.875rem;
  font-weight: 600;
}
.actas-bar__text { min-width: 0; overflow-wrap: anywhere; }
.actas-bar__stop { flex: none; min-height: 2.25rem; }
@media (pointer: coarse) {
  .actas-bar__stop { min-height: 2.75rem; }
}
</style>
