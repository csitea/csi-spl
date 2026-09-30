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
/* A SLIM one-line strip (owner 18597eaa: "this stripe is too big"): ~26 px
   high, small text centred, the Stop a small button pinned right. Same place
   (directly under the top bar, so it never covers the avatar menu), the same
   warning colour so it stays unmistakable, and fixed — it overlays, never
   pushing the layout by more than its own height. */
.actas-bar {
  position: fixed;
  top: var(--top-bar-h);
  left: 0;
  right: 0;
  z-index: calc(var(--z-banner) + 10);
  display: flex;
  align-items: center;
  gap: 0.5rem;
  box-sizing: border-box;
  min-height: 26px;
  padding: 2px 0.5rem;
  border-bottom: 1px solid var(--color-accent);
  background: color-mix(in srgb, var(--color-accent) 22%, var(--color-surface));
  color: var(--color-fg);
  font-size: 0.75rem;
  font-weight: 600;
  line-height: 1.3;
}
/* the message takes the width and centres; one line, ellipsis if it can't fit */
.actas-bar__text {
  flex: 1 1 auto;
  min-width: 0;
  text-align: center;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
/* a small link-style button at the right — overrides .btn's tall min-height */
.actas-bar__stop {
  flex: none;
  min-height: 0;
  padding: 1px 10px;
  font-size: 0.75rem;
  line-height: 1.4;
  border-radius: var(--radius-sm);
}
</style>
