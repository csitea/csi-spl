<!-- Spec 025 box owner lock, row B8 (SPL-3015): the lock of a machine box, on
     its Monitoring card. The hub answers the lock (GET /v1/boxes/{box}/lock,
     B2) to its owners only: an owner sees who owns it, its peer boxes and its
     audit; anyone else, and an unlocked box, reads "no lock you own" (the hub
     answers both 404, so the WUI cannot tell them apart and never says which).

     Locking is the owner's act on the box: `spool lock create` signs the lock
     with the lock key and the box key, and this dialog only carries its
     output (6.2). It shows the owners the output names and asks to confirm;
     the hub refuses a member who is not one of them (not_owner). A hub with
     no lock store (501) shows nothing. Lazy: the card loads it on mount. -->
<template>
  <section v-if="state !== 'unsupported'" class="box-lock" data-test="box-lock" :data-state="state" :aria-label="t('box_lock.title')">
    <h3><UiIcon name="lock" :size="18" /> {{ t('box_lock.title') }}</h3>
    <p v-if="state === 'loading'" class="muted" data-test="box-lock-loading">{{ t('box_lock.loading') }}</p>
    <p v-else-if="state === 'failed'" class="muted" role="alert" data-test="box-lock-failed">{{ t('box_lock.load_failed') }}</p>
    <template v-else-if="state === 'locked' && lock">
      <p class="box-lock__state" data-test="box-lock-locked">{{ t('box_lock.locked') }}</p>
      <p v-if="doneNote" class="muted" role="status" data-test="box-lock-done">{{ t('box_lock.done') }}</p>
      <dl class="box-lock__facts">
        <dt>{{ t('box_lock.owners') }}</dt>
        <dd data-test="box-lock-owners">
          <span v-for="o in lock.owners" :key="o" class="box-lock__owner" :data-key="o"><HumanName :id="o" box="box-wui" /></span>
        </dd>
        <dt>{{ t('box_lock.peers') }}</dt>
        <dd data-test="box-lock-peers">{{ lock.peers.length ? lock.peers.join(', ') : t('box_lock.no_peers') }}</dd>
        <dt>{{ t('box_lock.version') }}</dt>
        <dd data-test="box-lock-version">{{ lock.version }}</dd>
      </dl>
      <h4>{{ t('box_lock.audit') }}</h4>
      <p v-if="!lock.audit.length" class="muted" data-test="box-lock-audit-none">{{ t('box_lock.audit_none') }}</p>
      <div v-else class="box-lock__audit">
        <table data-test="box-lock-audit">
          <thead>
            <tr>
              <th scope="col">{{ t('box_lock.col_who') }}</th>
              <th scope="col">{{ t('box_lock.col_path') }}</th>
              <th scope="col">{{ t('box_lock.col_verdict') }}</th>
              <th scope="col">{{ t('box_lock.col_count') }}</th>
              <th scope="col">{{ t('box_lock.col_at') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(a, i) in lock.audit" :key="i" data-test="box-lock-audit-row">
              <td><code>{{ a.who || '—' }}</code></td>
              <td><code>{{ a.path }}</code></td>
              <td><code>{{ a.verdict }}</code></td>
              <td>{{ a.count }}</td>
              <td>{{ a.at ? isoDateTime(a.at) : '—' }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>
    <template v-else>
      <p class="muted" data-test="box-lock-none">{{ t('box_lock.none') }}</p>
      <button type="button" class="btn ghost" data-test="box-lock-open" @click="openConfirm">
        <UiIcon name="lock" :size="16" />
        <span>{{ t('box_lock.open') }}</span>
      </button>
    </template>

    <UiDialog v-model:open="confirmOpen" :title="t('box_lock.confirm_title')" size="md">
      <div class="box-lock__form" data-test="box-lock-confirm">
        <p>{{ t('box_lock.confirm_body') }}</p>
        <label class="box-lock__field">
          <span>{{ t('box_lock.paste_label', { cmd: BOX_LOCK_CREATE_CMD }) }}</span>
          <textarea
            v-model="pasted"
            rows="6"
            spellcheck="false"
            autocomplete="off"
            data-autofocus
            data-test="box-lock-paste"
            :disabled="busy"
          />
        </label>
        <p v-if="parsed && parsed.owners" class="box-lock__preview" data-test="box-lock-preview">
          {{ t('box_lock.preview', { owners: parsed.owners.join(', ') }) }}
        </p>
        <p v-if="error" class="box-lock__error" role="alert" data-test="box-lock-error">{{ t(error) }}</p>
      </div>
      <template #footer>
        <div class="box-lock__actions">
          <button type="button" class="btn ghost" :disabled="busy" data-test="box-lock-cancel" @click="confirmOpen = false">{{ t('common.cancel') }}</button>
          <button type="button" class="btn ghost danger" :disabled="busy || !parsed || !parsed.req" data-test="box-lock-confirm-btn" @click="confirmLock">
            <UiIcon name="lock" :size="16" />
            <span>{{ busy ? t('box_lock.locking') : t('box_lock.confirm') }}</span>
          </button>
        </div>
      </template>
    </UiDialog>
  </section>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { BOX_LOCK_CREATE_CMD, lockRefusalKey, lockViewOf, parseLockCreate } from '~/utils/box-lock.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'

const props = defineProps<{ box: string }>()
const { t } = useI18n({ useScope: 'global' })

type LockView = ReturnType<typeof lockViewOf>
const state = ref<'loading' | 'locked' | 'none' | 'failed' | 'unsupported'>('loading')
const lock = ref<LockView | null>(null)
const doneNote = ref(false)

let seq = 0
async function load() {
  const mine = ++seq
  state.value = 'loading'
  try {
    const row = await useSpoolApi().getBoxLock(props.box)
    if (mine !== seq) return
    lock.value = lockViewOf(row)
    state.value = 'locked'
  } catch (e) {
    if (mine !== seq) return
    const status = (e as { status?: number } | null)?.status
    lock.value = null
    state.value = status === 404 ? 'none' : status === 501 ? 'unsupported' : 'failed'
  }
}

const confirmOpen = ref(false)
const pasted = ref('')
const busy = ref(false)
const refusal = ref('')
/* the pasted output, checked as it is typed: the owners it names, or why not */
const parsed = computed(() => (pasted.value.trim() ? parseLockCreate(pasted.value.trim(), props.box) : null))
const error = computed(() => refusal.value || parsed.value?.error || '')
watch(pasted, () => { refusal.value = '' })

function openConfirm() {
  pasted.value = ''
  refusal.value = ''
  confirmOpen.value = true
}

async function confirmLock() {
  const req = parsed.value?.req
  if (!req || busy.value) return
  busy.value = true
  refusal.value = ''
  try {
    const row = await useSpoolApi().createBoxLock(props.box, req)
    lock.value = lockViewOf(row)
    state.value = 'locked'
    doneNote.value = true
    confirmOpen.value = false
  } catch (e) {
    refusal.value = lockRefusalKey(e)
  } finally {
    busy.value = false
  }
}

onMounted(() => { void load() })
watch(() => props.box, () => { doneNote.value = false; void load() })
</script>

<style scoped>
.box-lock h3 { margin: 0 0 6px; font-size: 0.9rem; display: flex; align-items: center; gap: 6px; }
.box-lock h4 { margin: 10px 0 4px; font-size: 0.85rem; }
.box-lock p { margin: 0 0 6px; }
.box-lock__state { font-weight: 600; }
.box-lock__facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 6px 14px; margin: 0; }
.box-lock__facts dt { color: var(--color-muted); font-size: 0.8125rem; }
.box-lock__facts dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
.box-lock__owner + .box-lock__owner::before { content: ', '; }
.box-lock__audit { max-width: 100%; overflow-x: auto; }
.box-lock__audit table { border-collapse: collapse; font-size: 0.8rem; }
.box-lock__audit th, .box-lock__audit td { padding: 3px 8px 3px 0; text-align: start; white-space: nowrap; }
.box-lock .btn { display: inline-flex; align-items: center; gap: 6px; }
.box-lock__form { display: flex; flex-direction: column; gap: 10px; padding: 8px 24px; overflow-wrap: anywhere; }
.box-lock__form p { margin: 0; }
.box-lock__field { display: flex; flex-direction: column; gap: 4px; }
.box-lock__field textarea { font-family: var(--font-mono, monospace); font-size: 0.8rem; width: 100%; box-sizing: border-box; }
.box-lock__preview { font-weight: 600; }
.box-lock__error { color: var(--color-danger); }
.box-lock__actions { display: flex; justify-content: flex-end; gap: 12px; flex-wrap: wrap; }
.box-lock__actions .btn { display: inline-flex; align-items: center; justify-content: center; gap: 6px; min-width: 104px; }
@media (max-width: 480px) {
  .box-lock__facts { grid-template-columns: minmax(0, 1fr); gap: 0; }
  .box-lock__facts dd + dt { margin-top: 8px; }
}
</style>
