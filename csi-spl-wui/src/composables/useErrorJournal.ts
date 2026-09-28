// csi-spl-wui/src/composables/useErrorJournal.ts
//
// Vue read-wrapper around errorJournal.mjs for the gated DebugPanel. The
// buffer is subscribed only after mount, so the prerendered markup (no panel)
// matches the first client render and `nuxt generate` cannot bake anything in.
//
// The gate lives here rather than in the component so it can be read in one
// place: `visible` is true only when the component is mounted AND the session
// claims (GET /api/v1/auth/session, spec 010 auth-v1 §3) carry the human's own
// "Debug pane" setting (Settings → Appearance). Anonymous,
// signed-out and "the probe could not answer" all resolve to no panel (fail
// shut). The claim is reactive, so ticking or unticking the box shows or hides
// the panel without a reload.
import { computed, onBeforeUnmount, onMounted, readonly, ref, shallowRef } from 'vue'
import {
  clearErrors,
  getErrors,
  subscribeErrors,
} from '@/composables/errorJournal.mjs'
import { debugPanelVisibleFor } from '@/composables/debugAudience.mjs'
import { useSessionStore } from '@/stores/session'

/**
 * One already-redacted record from errorJournal.mjs. The .mjs is untyped on
 * purpose (the unit suite executes it under bare `node`), so the shape is
 * declared here — and it declares exactly what the journal keeps. There is no
 * `body`, no `headers`, no `query` and no `stack` field, and that absence is
 * the data-minimisation control, not an omission.
 */
export interface ErrorRecord {
  seq: number
  ref: string
  errorId: string
  at: string
  source: string
  method: string
  origin: string
  path: string
  status: number
  code: string
  message: string
  name: string
  route: string
}

export function useErrorJournal() {
  const records = shallowRef<ErrorRecord[]>([])
  const mounted = ref(false)

  const session = useSessionStore()

  // The ONE gate: the human's own "Debug pane" setting in the session claims, nothing else.
  const privileged = computed(() =>
    session.state === 'in' && debugPanelVisibleFor(session.claims ?? null),
  )

  // Client-only by construction: `mounted` never becomes true on the server or
  // during prerender, so the panel contributes no markup to the static build.
  const visible = computed(() => mounted.value && privileged.value)

  onMounted(() => {
    mounted.value = true
    records.value = getErrors() as ErrorRecord[]
    const unsub = subscribeErrors((next) => {
      records.value = next as ErrorRecord[]
    })
    onBeforeUnmount(unsub)
  })

  return {
    records: readonly(records),
    privileged,
    visible,
    clear: clearErrors,
  }
}
