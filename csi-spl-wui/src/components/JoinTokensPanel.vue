<!-- Tenant settings -> Agents, spec 073 4.6 (spec 108 T010): New join token
     (label, optional box id, optional member = for_human), the open tokens
     list with Revoke, and per seated box Revoke seat with a confirm naming
     the box. agents.vue renders it only when the session holds agents.join,
     and loads it on demand. The token is shown once, from the mint answer,
     and Close drops it from memory. With spec 108's switch off for the
     workspace (section 3.8, the list's `enabled`) the new-token part is
     replaced by one line; open tokens and seats stay, to revoke. -->
<template>
  <div class="jt" data-test="join-tokens">
    <h3 class="jt__title">{{ t('join_tokens.title') }}</h3>
    <p class="muted jt__hint">{{ t('join_tokens.hint') }}</p>

    <div v-if="minted" class="jt__minted" role="dialog" :aria-label="t('join_tokens.minted_title')" data-test="join-token-minted">
      <p class="jt__strong">{{ t('join_tokens.minted_title') }}</p>
      <p class="muted">{{ t('join_tokens.minted_once') }}</p>
      <pre class="jt__line" data-test="join-token-line">{{ minted.line }}</pre>
      <div class="jt__actions">
        <button type="button" class="btn" data-test="join-token-copy" @click="copy">{{ t('join_tokens.copy') }}</button>
        <span v-if="copied" class="jt__ok" role="status" data-test="join-token-copied">{{ copied === 'ok' ? t('join_tokens.copied') : t('join_tokens.copy_failed') }}</span>
        <span class="jt__count" data-test="join-token-countdown">{{ left(minted.expiresAt) ? t('join_tokens.expires_in', { left: left(minted.expiresAt) }) : t('join_tokens.expired') }}</span>
        <button type="button" class="btn ghost" data-test="join-token-close" @click="closeMinted">{{ t('join_tokens.close') }}</button>
      </div>
    </div>

    <form v-else-if="formOpen && enabled" class="jt__form" data-test="join-token-form" @submit.prevent="mint">
      <label class="jt__field">
        <span>{{ t('join_tokens.label') }}</span>
        <input v-model="label" type="text" maxlength="80" autocomplete="off" data-test="join-token-label">
      </label>
      <label class="jt__field">
        <span>{{ t('join_tokens.box_id') }}</span>
        <input v-model="boxId" type="text" maxlength="32" autocomplete="off" :placeholder="t('join_tokens.box_id_any')" data-test="join-token-box">
      </label>
      <label class="jt__field">
        <span>{{ t('join_tokens.for_human') }}</span>
        <select v-model="forHuman" data-test="join-token-for-human">
          <option value="">{{ t('join_tokens.for_nobody') }}</option>
          <option v-for="m in members" :key="m.id" :value="m.id">{{ m.name }} ({{ m.id }})</option>
        </select>
      </label>
      <div class="jt__actions">
        <button type="submit" class="btn" :disabled="busy" data-test="join-token-mint">{{ t('join_tokens.mint') }}</button>
        <button type="button" class="btn ghost" :disabled="busy" @click="formOpen = false">{{ t('join_tokens.cancel') }}</button>
      </div>
    </form>

    <button v-else-if="enabled" type="button" class="btn ghost" data-test="join-token-new" @click="openForm">{{ t('join_tokens.new') }}</button>

    <p v-else class="muted" data-test="join-tokens-disabled">{{ t('join_tokens.disabled') }}</p>

    <p v-if="error" class="jt__error" role="alert" data-test="join-token-error">{{ error }}</p>

    <h4 class="jt__sub">{{ t('join_tokens.open_title') }}</h4>
    <p v-if="!tokens.length" class="muted" data-test="join-tokens-empty">{{ t('join_tokens.none') }}</p>
    <ul v-else class="jt__list" data-test="join-tokens-list">
      <li v-for="r in tokens" :key="r.id" class="jt__row" data-test="join-token-row" :data-id="r.id" :data-state="r.state">
        <code>{{ r.id }}</code>
        <span class="jt__main">{{ r.label || r.boxId || t('join_tokens.any_box') }}</span>
        <span class="muted jt__meta">{{ t('join_tokens.state_' + r.state) }}</span>
        <span class="muted jt__meta">{{ left(r.expiresAt) ? t('join_tokens.expires_in', { left: left(r.expiresAt) }) : t('join_tokens.expired') }}</span>
        <span class="muted jt__meta">{{ t('join_tokens.minted_by', { who: r.createdBy || '-' }) }}</span>
        <span v-if="r.forHuman" class="muted jt__meta">{{ t('join_tokens.for_who', { who: r.forHuman }) }}</span>
        <button v-if="r.state === 'open'" type="button" class="btn ghost jt__btn" :disabled="busy" data-test="join-token-revoke" @click="revoke(r.id)">{{ t('join_tokens.revoke') }}</button>
      </li>
    </ul>

    <h4 class="jt__sub">{{ t('join_tokens.seats_title') }}</h4>
    <p v-if="!boxes.length" class="muted" data-test="join-seats-empty">{{ t('join_tokens.no_seats') }}</p>
    <ul v-else class="jt__list" data-test="join-seats-list">
      <li v-for="b in boxes" :key="b" class="jt__row" data-test="join-seat-row" :data-box="b">
        <code class="jt__main">{{ b }}</code>
        <template v-if="confirming === b">
          <span class="jt__warn" data-test="join-seat-confirm-text">{{ t('join_tokens.revoke_seat_confirm', { box: b }) }}</span>
          <button type="button" class="btn jt__btn jt__danger" :disabled="busy" data-test="join-seat-confirm" @click="revokeSeat(b)">{{ t('join_tokens.revoke_seat') }}</button>
          <button type="button" class="btn ghost jt__btn" :disabled="busy" data-test="join-seat-cancel" @click="confirming = ''">{{ t('join_tokens.cancel') }}</button>
        </template>
        <button v-else type="button" class="btn ghost jt__btn" :disabled="busy" data-test="join-seat-revoke" @click="confirming = b">{{ t('join_tokens.revoke_seat') }}</button>
      </li>
    </ul>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { writeClipboard } from '~/utils/clipboard.mjs'
import { joinCountdown, joinEnabled, joinMemberOptions, joinMintBody, joinTokenRows, seatedBoxes } from '~/utils/join-tokens.mjs'

const props = defineProps<{ seats: Array<{ box: string }> }>()
const emit = defineEmits<{ revoked: [box: string] }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

type Row = ReturnType<typeof joinTokenRows>[number]
const tokens = ref<Row[]>([])
const members = ref<Array<{ id: string, name: string }>>([])
const boxes = computed(() => seatedBoxes(props.seats))
const formOpen = ref(false)
const label = ref('')
const boxId = ref('')
const forHuman = ref('')
const busy = ref(false)
const error = ref('')
const copied = ref<'' | 'ok' | 'fail'>('')
const confirming = ref('')
/* spec 108's switch for this workspace, from the list answer */
const enabled = ref(true)
/* the one mint answer: held only while its panel is open */
const minted = ref<{ line: string, expiresAt: string } | null>(null)
const now = ref(Date.now())
let tick: ReturnType<typeof setInterval> | null = null

const left = (at: string) => joinCountdown(at, now.value)

function fail(e: unknown) {
  const err = e as { detail?: string, status?: number, token?: string }
  if (err?.token === 'box_join_disabled') {
    enabled.value = false
    formOpen.value = false
    error.value = ''
  } else if (err?.status === 403) error.value = t('join_tokens.forbidden')
  else error.value = err?.detail || t('join_tokens.failed')
}

async function loadTokens() {
  try {
    const body = await api.listJoinTokens()
    tokens.value = joinTokenRows(body)
    enabled.value = joinEnabled(body)
  } catch (e) {
    fail(e)
  }
}

async function openForm() {
  error.value = ''
  formOpen.value = true
  if (members.value.length) return
  try {
    members.value = joinMemberOptions(await api.listTenantUsers())
  } catch {
    /* the member list is optional: mint without for_human still works */
  }
}

async function mint() {
  if (busy.value) return
  busy.value = true
  error.value = ''
  try {
    const r = await api.mintJoinToken(joinMintBody({ label: label.value, boxId: boxId.value, forHuman: forHuman.value }))
    minted.value = { line: r.join_line || `SPOOL_JOIN_TOKEN=${r.token} spool join`, expiresAt: r.expires_at }
    formOpen.value = false
    label.value = ''
    boxId.value = ''
    forHuman.value = ''
    await loadTokens()
  } catch (e) {
    fail(e)
  } finally {
    busy.value = false
  }
}

async function copy() {
  if (!minted.value) return
  copied.value = (await writeClipboard(minted.value.line)) ? 'ok' : 'fail'
}

function closeMinted() {
  minted.value = null
  copied.value = ''
}

async function revoke(id: string) {
  if (busy.value) return
  busy.value = true
  error.value = ''
  try {
    await api.revokeJoinToken(id)
    await loadTokens()
  } catch (e) {
    fail(e)
  } finally {
    busy.value = false
  }
}

async function revokeSeat(box: string) {
  if (busy.value) return
  busy.value = true
  error.value = ''
  try {
    await api.revokeSeat(box)
    confirming.value = ''
    emit('revoked', box)
  } catch (e) {
    fail(e)
  } finally {
    busy.value = false
  }
}

onMounted(() => {
  void loadTokens()
  tick = setInterval(() => { now.value = Date.now() }, 1000)
})
onBeforeUnmount(() => {
  if (tick) clearInterval(tick)
  minted.value = null
})
</script>

<style scoped>
.jt { margin-top: 14px; padding-top: 12px; border-top: 1px solid var(--color-border); }
.jt__title { margin: 0 0 4px; font-size: 1rem; }
.jt__sub { margin: 14px 0 6px; font-size: 0.875rem; }
.jt__hint { margin: 0 0 10px; }
.jt__strong { margin: 0; font-weight: 600; }
.jt__minted { padding: 10px; border: 1px solid var(--color-border-strong); background: var(--color-surface); }
.jt__line { margin: 8px 0; padding: 8px; white-space: pre-wrap; overflow-wrap: anywhere; font-size: 0.8125rem; background: var(--color-bg); border: 1px solid var(--color-border); }
.jt__form { display: flex; flex-direction: column; gap: 8px; max-width: 420px; }
.jt__field { display: flex; flex-direction: column; gap: 2px; font-size: 0.8125rem; }
.jt__field input, .jt__field select {
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
  font-size: 0.875rem;
}
.jt__actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.jt__count { font-size: 0.8125rem; color: var(--color-muted); }
.jt__ok { font-size: 0.8125rem; color: var(--color-ok); }
.jt__error { margin: 8px 0 0; color: var(--color-danger); overflow-wrap: anywhere; }
.jt__warn { font-size: 0.8125rem; color: var(--color-danger); overflow-wrap: anywhere; }
.jt__list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.jt__row { display: flex; align-items: center; gap: 10px; min-height: 36px; padding: 2px 4px; flex-wrap: wrap; min-width: 0; }
.jt__main { flex: 1 1 auto; min-width: 0; overflow-wrap: anywhere; }
.jt__meta { font-size: 0.8125rem; }
.jt__btn { flex: none; padding: 2px 10px; font-size: 0.8125rem; }
.jt__danger { color: var(--color-danger); }
@media (max-width: 820px) {
  .jt__row { min-height: var(--tap, 44px); }
  .jt .btn, .jt__field input, .jt__field select { min-height: var(--tap, 44px); }
}
</style>
