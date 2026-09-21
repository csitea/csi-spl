<!-- One error, said once, with something the reader can quote (ported from
     the donor WUI's common/ErrorNotice.vue).

     A localized sentence with no handle on it leaves an operator grepping the
     hub log by guesswork. This component adds the handle: a copyable
     `ERR-YYYYMMDD-HHMMSS-XXXX` that is the SAME string the server wrote into
     its log line when it sent one, so a screenshot and a log entry join.

     WHERE THE ID COMES FROM, in order:
       1. an explicit `error-id` prop — a caller that already resolved one;
       2. the rejection in `error`, via errorJournal's `extractErrorId`, which
          admits a value ONLY if it is exactly an id;
       3. failing both, a fresh `ERR-CLIENT-…` minted here AND written to the
          journal, so the reference a reader quotes is one an operator can
          find in the diagnostics panel.

     THE ID IS TECHNICAL TEXT and never passes through `t()`; `dir="ltr"`
     keeps it un-mirrored. The MESSAGE is the caller's — this component does
     not classify errors, it only presents one. -->
<template>
  <div class="error-notice" role="alert" :data-test="testId">
    <UiIcon class="error-notice__icon" name="alert-triangle" :size="18" />
    <div class="error-notice__body">
      <p class="error-notice__message" :data-test="`${testId}-message`">
        <slot>{{ message }}</slot>
      </p>

      <slot name="detail" />

      <p v-if="errorId" class="error-notice__meta">
        <span class="error-notice__label">{{ t('common.error_ref') }}</span>
        <code
          class="error-notice__code"
          dir="ltr"
          :data-test="`${testId}-ref`"
        >{{ errorId }}</code>
        <button
          type="button"
          class="error-notice__copy"
          :title="copyTitle"
          :aria-label="copyTitle"
          :data-test="`${testId}-copy`"
          @click="copy"
        >
          <UiIcon :name="copyState === 'ok' ? 'check' : 'copy'" :size="14" />
        </button>
        <span
          v-if="copyState"
          class="error-notice__feedback"
          :data-test="`${testId}-copy-state`"
        >{{ copyTitle }}</span>
      </p>

      <slot name="actions" />
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'

import {
  extractErrorId,
  newClientErrorId,
  noteError,
} from '@/composables/errorJournal.mjs'

const props = withDefaults(
  defineProps<{
    /** The localized sentence to show. Overridable by the default slot. */
    message?: string
    /** An id the caller already has. Wins over everything else. */
    errorId?: string
    /** The rejection this notice is about, if the caller kept it. */
    error?: unknown
    /**
     * `data-test` root. Every call site keeps the selector its own suite and
     * e2e walk already use, so adopting this component never silently retires
     * someone else's test.
     */
    testId?: string
    /** Where the minted client id says it came from, in the journal. */
    source?: string
  }>(),
  { message: '', errorId: '', error: undefined, testId: 'error-notice', source: 'ui' },
)

const { t } = useI18n({ useScope: 'global' })

// Resolved once per distinct failure, never per render: minting inside a
// computed would hand the reader a new id every time Vue re-evaluated, and an
// id that changes while you are copying it is worse than no id.
const minted = ref('')

// AFTER MOUNT, never during the render that hydrates. A minted id embeds the
// current second and four random hex digits, so producing one while
// `nuxt generate` or SSR is rendering would bake a value the client cannot
// reproduce — a hydration mismatch, and a stale timestamp baked into a static
// page. A SERVER-supplied id has no such problem: it is a prop, identical on
// both sides, so the chip renders on the first paint in that case.
function resolve(): void {
  if (props.errorId || extractErrorId(props.error)) {
    minted.value = ''
    return
  }
  if (!props.message && props.error == null) {
    // Nothing to report yet — a v-if that has not flipped, or an empty slot.
    minted.value = ''
    return
  }
  const id = newClientErrorId()
  minted.value = id
  // Written to the journal so the reference is findable, and carried to the
  // RUM beacon with it. `noteError` never throws and is a no-op on the server.
  //
  // This is not a second record for a failure already captured: anything the
  // journal has seen leaves a stamped id on the rejection, so getting here at
  // all means the fetch layer never saw this one.
  noteError({
    source: props.source,
    message: props.message,
    error: props.error,
    errorId: id,
  })
}

const mounted = ref(false)
onMounted(() => {
  mounted.value = true
  resolve()
})

watch(
  () => [props.errorId, props.error, props.message],
  () => { if (mounted.value) resolve() },
)

const errorId = computed(
  () => props.errorId || extractErrorId(props.error) || minted.value,
)

type CopyState = '' | 'ok' | 'fail'
const copyState = ref<CopyState>('')
let clearTimer: ReturnType<typeof setTimeout> | undefined

const copyTitle = computed(() =>
  copyState.value === 'ok'
    ? t('common.copied')
    : copyState.value === 'fail'
      ? t('common.copy_failed')
      : t('common.copy_ref'),
)

async function copy(): Promise<void> {
  // Clipboard access is refused outright in some contexts (insecure origin, a
  // permissions policy). That is a state to SHOW, never an exception to throw —
  // this control renders when the page is already unwell.
  try {
    await navigator.clipboard.writeText(errorId.value)
    copyState.value = 'ok'
  } catch {
    copyState.value = 'fail'
  }
  if (clearTimer) clearTimeout(clearTimer)
  clearTimer = setTimeout(() => { copyState.value = '' }, 2500)
}
</script>

<style scoped>
/* Contained on every axis: a long id must wrap rather than widen the document
   (no horizontal document scroll on mobile). */
.error-notice {
  display: flex;
  gap: 0.5rem;
  align-items: flex-start;
  max-width: 100%;
  padding: 0.6rem 0.75rem;
  border: 1px solid var(--color-danger);
  border-radius: var(--radius-sm);
  background: color-mix(in srgb, var(--color-danger) 10%, var(--color-surface));
  color: var(--color-fg);
}

.error-notice__icon { flex: none; margin-top: 0.1rem; color: var(--color-danger); }

.error-notice__body { min-width: 0; flex: 1 1 auto; }

.error-notice__message {
  margin: 0;
  overflow-wrap: anywhere;
}

.error-notice__meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.35rem;
  margin: 0.4rem 0 0;
  font-size: 0.85rem;
}

.error-notice__label { opacity: 0.85; }

.error-notice__code {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.85em;
  padding: 0.1rem 0.35rem;
  border-radius: var(--radius-sm);
  background: color-mix(in srgb, var(--color-fg) 8%, transparent);
  overflow-wrap: anywhere;
}

.error-notice__copy {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 0.15rem;
  border: 0;
  border-radius: var(--radius-sm);
  background: transparent;
  color: inherit;
  cursor: pointer;
}

.error-notice__copy:hover { background: color-mix(in srgb, var(--color-fg) 10%, transparent); }

.error-notice__feedback { opacity: 0.85; }
</style>
