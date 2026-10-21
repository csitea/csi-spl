<!-- SPL-2785 (owner HUM-10, t1 c7185b1f): after a Back on a phone, three
     small bouncing dots while the screen it returns to is not ready yet,
     like the meetup web app. Every Back counts the same (the chevron, a
     swipe right, browser Back: useMobileStack's `backs`). Shown only when
     the wait passes BACK_WAIT_MS, so an instant Back never flashes; gone the
     moment the screen is ready. Ready = no route still resolving and nothing
     in the shell marked aria-busy (the feed while it loads) or still held by
     a late placeholder (.shell-late). The layout mounts it on a phone only,
     as its own lazy chunk; the drawing is await-anim/Dots.vue, whose
     keyframes move only under prefers-reduced-motion: no-preference. -->
<template>
  <div
    class="back-wait"
    role="status"
    aria-live="polite"
    :aria-busy="shown ? 'true' : 'false'"
    data-testid="back-wait"
    :data-shown="shown ? 'true' : undefined"
  >
    <template v-if="shown">
      <span class="back-wait__pill await-reply--spin" data-testid="back-wait-dots"><Dots /></span>
      <span class="sr-only">{{ t('common.loading') }}</span>
    </template>
  </div>
</template>

<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue'
import Dots from '~/components/await-anim/Dots.vue'
import { useMobileStack } from '~/composables/useMobileStack'

const BACK_WAIT_MS = 150
const POLL_MS = 100
/* a screen that never says it is ready must not keep the dots forever */
const GIVE_UP_MS = 15000

const { t } = useI18n({ useScope: 'global' })
const stack = useMobileStack()
const shown = ref(false)

/* a route still resolving: from beforeEach until afterEach, and a page whose
   setup suspends until Nuxt's page:finish */
const router = useRouter()
const nuxtApp = useNuxtApp()
let navigating = false
let suspended = false
const offBefore = router.beforeEach(() => { navigating = true })
const offAfter = router.afterEach(() => { navigating = false })
const offStart = nuxtApp.hook('page:start', () => { suspended = true })
const offFinish = nuxtApp.hook('page:finish', () => { suspended = false })

function visible(e: Element) {
  const r = e.getBoundingClientRect()
  return r.width > 0 && r.height > 0
}

function busy() {
  if (navigating || suspended) return true
  const shell = document.querySelector('.spool-shell')
  if (!shell) return false
  return [...shell.querySelectorAll('[aria-busy="true"], .shell-late')].some(visible)
}

let timer: ReturnType<typeof setTimeout> | undefined
let until = 0

function stop() {
  clearTimeout(timer)
  shown.value = false
}

function check() {
  if (!busy() || Date.now() > until) return stop()
  shown.value = true
  timer = setTimeout(check, POLL_MS)
}

watch(stack.backs, () => {
  stop()
  until = Date.now() + GIVE_UP_MS
  timer = setTimeout(check, BACK_WAIT_MS)
})

onBeforeUnmount(() => { stop(); offBefore(); offAfter(); offStart(); offFinish() })
</script>

<style scoped>
.back-wait {
  position: fixed;
  inset-inline: 0;
  top: 40%;
  z-index: calc(var(--z-sticky, 40) + 5);
  display: flex;
  justify-content: center;
  pointer-events: none;
}
.back-wait__pill {
  display: inline-grid;
  place-items: center;
  padding: 8px 16px;
  border-radius: var(--radius-pill);
  background: var(--color-sidebar);
  border: 1px solid var(--color-border-strong);
  color: var(--color-accent);
  box-shadow: 0 4px 14px rgb(0 0 0 / 0.22);
}
/* the shared drawing is 20 px; here it stands alone, so a little larger */
.back-wait__pill :deep(svg) { inline-size: 32px; block-size: 32px; }
@media (prefers-reduced-motion: no-preference) {
  .back-wait__pill { animation: back-wait-in 0.15s ease-out; }
}
@keyframes back-wait-in {
  from { opacity: 0; }
  to { opacity: 1; }
}
</style>
