<!-- SPL-1839 (owner HUM-10, t1 659e3927, msg 4de3b04e): "the error msgs could
     be simple error msging explainning to the regular user what happens ...
     and only when the debug pane is selected to present the technical jibr".

     SearchErrorNotice (SPL-1833) did it for search; this is the same pattern
     for the other screens that showed the red ErrorNotice with the raw store
     message (#lobby, a channel feed, a topic pane) and for the red top
     snackbar: ONE plain sentence - what happened and what to do - and a
     Try again button when the caller can retry. The technical part (HTTP
     status, the raw message, the reference id) shows ONLY with the existing
     Debug pane setting on (debugAudience.mjs).

     The failure is still journaled: a caller's id (`error-id`, a journal
     record) is kept; otherwise a reference is minted and journaled `inline`,
     so the snackbar does not say it a second time. Technical text never
     passes through t().

     On demand (i18n-first-screen.mjs): its strings wait in the second
     catalogue; until that is merged it says the core "Something went wrong"
     and offers no button (te() below), so no first paint shows a raw key.

     `compact`: the sentence (and the debug line) only, no box, no button and
     no journaling - the snackbar row, whose record is already journaled. -->
<template>
  <div
    class="plain-err"
    :class="{ 'plain-err--compact': compact }"
    :data-test="testId"
    :role="compact ? undefined : 'status'"
    :aria-live="compact ? undefined : 'polite'"
  >
    <p class="plain-err__msg" :data-test="`${testId}-message`">{{ sentence }}</p>
    <button
      v-if="retry && !compact && te('plain_err.retry')"
      type="button"
      class="btn plain-err__retry"
      :data-test="`${testId}-retry`"
      @click="emit('retry')"
    >
      {{ t('plain_err.retry') }}
    </button>
    <p v-if="debug && techLine" class="plain-err__tech" dir="ltr" :data-test="`${testId}-tech`">
      <code>{{ techLine }}</code>
    </p>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { extractErrorId, newClientErrorId, noteError } from '@/composables/errorJournal.mjs'
import { debugPanelVisibleFor } from '~/composables/debugAudience.mjs'
import { useSessionStore } from '~/stores/session'
import { plainErrorKind, plainErrorStatus } from '~/utils/plain-error.mjs'

const props = withDefaults(defineProps<{
  /** The technical text the store kept ("spool 500 internal", "Failed to fetch"). */
  message?: string
  /** The rejection itself, when the caller kept it. */
  error?: unknown
  /** HTTP status, when the caller knows it (else read from message / error). */
  status?: number
  /** An id the caller already has (a journal record): nothing is minted. */
  errorId?: string
  /** What failed: `load` = this screen's content, `other` = some action. */
  what?: 'load' | 'other'
  /** Show Try again (the caller handles @retry). */
  retry?: boolean
  compact?: boolean
  testId?: string
  /** Where a minted reference says it came from, in the journal. */
  source?: string
}>(), { message: '', error: undefined, status: 0, errorId: '', what: 'load', retry: false, compact: false, testId: 'plain-error', source: 'ui' })
const emit = defineEmits<{ retry: [] }>()

const { t, te } = useI18n({ useScope: 'global' })
const session = useSessionStore()

const debug = computed(() => session.state === 'in' && debugPanelVisibleFor(session.claims ?? null))
const status = computed(() => props.status || plainErrorStatus(props.message, props.error))
const kind = computed(() => plainErrorKind(status.value, props.message, props.error, props.what))
const sentence = computed(() => (te('plain_err.retry') ? t(`plain_err.${kind.value}`) : t('error.title_other')))

/* one id per distinct failure, after mount (never during a prerender) */
const refId = ref('')
function resolve() {
  const known = props.errorId || extractErrorId(props.error)
  if (known || props.compact) {
    refId.value = known
    return
  }
  if (!props.message && props.error == null) {
    refId.value = ''
    return
  }
  refId.value = newClientErrorId()
  noteError({ source: props.source, message: props.message, error: props.error, errorId: refId.value, inline: true })
}
onMounted(resolve)
watch([() => props.message, () => props.error, () => props.errorId], resolve)

const techLine = computed(() => {
  const parts: string[] = []
  if (status.value) parts.push(`HTTP ${status.value}`)
  if (props.message) parts.push(props.message)
  const raw = String((props.error as { message?: unknown } | null | undefined)?.message || '')
  if (raw && raw !== props.message) parts.push(raw)
  if (refId.value) parts.push(refId.value)
  return parts.join(' · ')
})
</script>

<style scoped>
.plain-err { margin: 8px 0; }
.plain-err--compact { margin: 0; }
.plain-err__msg { margin: 0 0 8px; overflow-wrap: anywhere; }
.plain-err--compact .plain-err__msg { margin: 0; font-size: 0.875rem; }
.plain-err__retry { min-height: var(--tap, 44px); }
.plain-err__tech { margin: 8px 0 0; font-size: 0.8125rem; color: var(--color-muted, inherit); }
.plain-err--compact .plain-err__tech { margin: 0.15rem 0 0; font-size: 0.75rem; }
.plain-err__tech code { font-family: var(--font-mono); overflow-wrap: anywhere; }
@media (min-width: 821px) { .plain-err__retry { min-height: 0; } }
</style>
