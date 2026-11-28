<!-- Spec 169 8.5.4 to 8.5.6 (row T19): the "Move to workspace" dialog of a
     channel row's menu. Three screens, then the stuck table:
       plan     the target (the probe's list, 8.5.2) and the plan in words:
                counts, mentions left in place, shared files, the kept list,
                and a checkbox per person who loses access (T7d keep)
       blocked  shown instead of the confirm while anything stops the move,
                each line with what clears it; an hours stop has "leave these
                rows" (T7d leave_hours)
       confirm  one button, enabled only with nothing blocked; the click is
                the person's GO (8.5.5, Q9 A): the hub writes it and runs P1
       status   GET /v1/channel-moves/{move_id} (T17), 8.5.6's table
     No copy, no new name, no retry, no cancel (8.5.1, 8.5.6). Loaded lazily
     (LazyChannelWorkspaceMoveDialog), so it stays off the initial script. -->
<template>
  <UiDialog :open="open" :title="t('channel_move.title', { name })" size="md" @update:open="emit('update:open', $event)">
    <div class="cwm" data-testid="channel-move" :data-screen="screen">
      <section v-if="screen === 'plan'" data-testid="channel-move-plan">
        <label class="cwm__field">
          <span>{{ t('channel_move.target') }}</span>
          <select v-model="dst" data-testid="channel-move-target" data-autofocus :disabled="busy">
            <option value="" disabled>{{ t('channel_move.target_pick') }}</option>
            <option v-for="w in targets" :key="w.slug" :value="w.slug">{{ w.name }}</option>
          </select>
        </label>
        <p v-if="!targets.length" class="muted" data-testid="channel-move-no-targets">{{ t('channel_move.no_targets') }}</p>
        <p v-if="busy && !plan" class="muted">{{ t('common.loading') }}</p>
        <template v-if="plan">
          <h3 class="cwm__head">{{ t('channel_move.counts') }}</h3>
          <ul class="cwm__list" data-testid="channel-move-counts">
            <li v-for="c in counts" :key="c.table">{{ t('channel_move.count_row', { table: c.table, n: c.n }) }}</li>
          </ul>
          <template v-if="lost.length">
            <h3 class="cwm__head">{{ t('channel_move.members_lost') }}</h3>
            <ul class="cwm__list" data-testid="channel-move-lost">
              <li v-for="h in lost" :key="h">
                <label><input v-model="keep" type="checkbox" :value="h" data-testid="channel-move-keep" :disabled="busy"> {{ t('channel_move.keep', { who: h, dst: dstName }) }}</label>
              </li>
            </ul>
          </template>
          <template v-if="mentions.length">
            <h3 class="cwm__head">{{ t('channel_move.mentions') }}</h3>
            <ul class="cwm__list" data-testid="channel-move-mentions"><li v-for="(m, i) in mentions" :key="i">{{ m }}</li></ul>
          </template>
          <template v-if="shared.length">
            <h3 class="cwm__head">{{ t('channel_move.shared_files') }}</h3>
            <ul class="cwm__list" data-testid="channel-move-shared"><li v-for="f in shared" :key="f">{{ f }}</li></ul>
          </template>
          <details v-if="kept.length" class="cwm__kept">
            <summary>{{ t('channel_move.kept') }}</summary>
            <ul class="cwm__list" data-testid="channel-move-kept"><li v-for="k in kept" :key="k.store">{{ t('channel_move.kept_row', { store: k.store, until: k.until }) }}</li></ul>
          </details>
        </template>
      </section>

      <section v-else-if="screen === 'blocked'" data-testid="channel-move-blocked">
        <p>{{ t('channel_move.blocked_intro', { dst: dstName }) }}</p>
        <ul class="cwm__list">
          <li v-for="s in stops" :key="s.line" data-testid="channel-move-stop" :data-kind="s.kind">
            <code class="cwm__line">{{ s.line }}</code>
            <span class="muted">{{ t(`channel_move.clears.${s.kind}`) }}</span>
            <label v-if="s.member">
              <input v-model="leave" type="checkbox" :value="s.member" data-testid="channel-move-leave" :disabled="busy"> {{ t('channel_move.leave_hours', { who: s.member }) }}
            </label>
          </li>
        </ul>
      </section>

      <section v-else-if="screen === 'confirm'" data-testid="channel-move-confirm">
        <p>{{ t('channel_move.confirm_body', { name, dst: dstName }) }}</p>
        <ul class="cwm__list"><li v-for="c in counts" :key="c.table">{{ t('channel_move.count_row', { table: c.table, n: c.n }) }}</li></ul>
        <p v-if="lostAfter.length" data-testid="channel-move-confirm-lost">{{ t('channel_move.confirm_lost', { who: lostAfter.join(', ') }) }}</p>
        <p class="cwm__warn"><strong>{{ t('channel_move.no_undo') }}</strong></p>
      </section>

      <section v-else data-testid="channel-move-status" :data-state="view?.state || ''">
        <p v-if="!view && !statusGone" class="muted">{{ t('common.loading') }}</p>
        <template v-else-if="statusGone">
          <p data-testid="channel-move-status-gone">{{ t('channel_move.status_gone') }}</p>
        </template>
        <template v-else-if="view">
          <p data-testid="channel-move-line">{{ t(`channel_move.state.${view.state}`, { dst: view.dst, src: view.src }) }}</p>
          <p v-if="view.reason" data-testid="channel-move-reason"><code class="cwm__line">{{ view.reason }}</code></p>
          <p v-if="view.state === 'not_moved'" class="muted">{{ t('channel_move.rerun') }}</p>
          <ul v-if="view.proofs.length" class="cwm__list" data-testid="channel-move-proofs">
            <li v-for="p in view.proofs" :key="p.name">{{ t('channel_move.proof_row', { name: p.name, n: p.count }) }}</li>
          </ul>
          <ul v-if="view.kept.length" class="cwm__list" data-testid="channel-move-status-kept">
            <li v-for="k in view.kept" :key="k.store">{{ t('channel_move.kept_row', { store: k.store, until: k.until }) }}</li>
          </ul>
          <p v-if="view.link"><a :href="view.link" data-testid="channel-move-link">{{ t('channel_move.open_channel', { dst: view.dst }) }}</a></p>
        </template>
        <p v-if="topicHref"><a :href="topicHref" data-testid="channel-move-topic">{{ t('channel_move.open_topic') }}</a></p>
      </section>

      <p v-if="error" class="cwm__error" role="alert" data-testid="channel-move-error">{{ error }}</p>
    </div>
    <template #footer>
      <div class="cwm__actions">
        <button type="button" class="btn ghost" :disabled="busy" @click="back">{{ screen === 'plan' || screen === 'status' ? t('common.close') : t('channel_move.back') }}</button>
        <button v-if="screen === 'plan'" type="button" class="btn" data-testid="channel-move-next" :disabled="busy || !plan" @click="next">{{ t('channel_move.next') }}</button>
        <button v-else-if="screen === 'blocked'" type="button" class="btn" data-testid="channel-move-recheck" :disabled="busy" @click="recheck">{{ t('channel_move.recheck') }}</button>
        <button v-else-if="screen === 'confirm'" type="button" class="btn danger" data-testid="channel-move-go" :disabled="busy || stops.length > 0" @click="confirm">{{ busy ? t('channel_move.busy') : t('channel_move.go', { dst: dstName }) }}</button>
      </div>
    </template>
  </UiDialog>
</template>

<script setup lang="ts">
import { useSpoolApi, tenantHostUrl } from '~/composables/useSpoolApi'
import { blockedLines, countRows, moveBody, openMoveId, screenAfterPlan, statusView, stopKind } from '~/utils/channel-workspace-move.mjs'

type Plan = Awaited<ReturnType<ReturnType<typeof useSpoolApi>['channelWorkspaceMovePlan']>>
type Screen = 'plan' | 'blocked' | 'confirm' | 'status'

const props = defineProps<{ open: boolean, channelId: string, name: string, targets: { slug: string, name: string }[] }>()
const emit = defineEmits<{ 'update:open': [boolean] }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

/* a confirmed move per channel, for this page: reopening the dialog reads
   where it stands instead of offering a second GO (8.5.6) */
const confirmed = moveMemo()

const screen = ref<Screen>('plan')
const dst = ref('')
const plan = ref<Plan | null>(null)
const keep = ref<string[]>([])
const leave = ref<string[]>([])
const busy = ref(false)
const error = ref('')
const status = ref<Record<string, unknown> | null>(null)
const statusGone = ref(false)
const topicHref = ref('')
/* the latest plan ask wins: a pick while a plan is on its way drops the older answer */
let planSeq = 0

const dstName = computed(() => props.targets.find((w) => w.slug === dst.value)?.name || dst.value)
const counts = computed(() => countRows(plan.value))
const lost = computed(() => (plan.value?.members_lost || []).map(String))
const lostAfter = computed(() => lost.value.filter((h) => !keep.value.includes(h)))
const mentions = computed(() => (plan.value?.mentions || []).map((m) => String(m?.line || '')).filter(Boolean))
const shared = computed(() => (plan.value?.shared_files || []).map(String))
const kept = computed(() => (plan.value?.kept || []).map((k) => ({ store: String(k?.store || ''), until: String(k?.gone_by || '') })))
const stops = computed(() => blockedLines(plan.value).map((line) => ({ line, ...stopKind(line) })))
const view = computed(() => (status.value ? statusView(status.value) : null))

function reset() {
  screen.value = 'plan'
  plan.value = null
  keep.value = []
  leave.value = []
  error.value = ''
  status.value = null
  statusGone.value = false
  topicHref.value = ''
  dst.value = props.targets.length === 1 ? props.targets[0]!.slug : ''
}

watch(() => props.open, (v) => {
  if (!v) return
  reset()
  const was = confirmed.get(props.channelId)
  if (was) void showStatus(was.moveId, was.topic)
  else if (dst.value) void loadPlan()
}, { immediate: true })
/* a pick asks for the plan; the one target picked on open is asked above */
watch(dst, (v) => { if (props.open && screen.value === 'plan' && v) void loadPlan() })

function body() {
  return moveBody(dst.value, { keep: keep.value, leaveHours: leave.value })
}

function hubCopy(e: unknown): string {
  const tok = (e && typeof e === 'object' && 'token' in e) ? String((e as { token?: unknown }).token || '') : ''
  return ['channel_move_owner', 'go_required', 'move_refused', 'unknown_tenant', 'bad_channel'].includes(tok)
    ? t(`channel_move.error.${tok}`)
    : t('channel_move.error.fallback')
}

async function loadPlan() {
  if (!dst.value) return
  const seq = ++planSeq
  busy.value = true
  error.value = ''
  try {
    const p = await api.channelWorkspaceMovePlan(props.channelId, body())
    if (seq === planSeq) plan.value = p
  } catch (e) {
    if (seq !== planSeq) return
    plan.value = null
    error.value = hubCopy(e)
  } finally {
    if (seq === planSeq) busy.value = false
  }
}

async function next() {
  await loadPlan()
  if (plan.value) screen.value = screenAfterPlan(plan.value)
}

async function recheck() {
  await loadPlan()
  if (plan.value) screen.value = screenAfterPlan(plan.value)
}

function back() {
  if (screen.value === 'plan' || screen.value === 'status') emit('update:open', false)
  else screen.value = 'plan'
}

async function confirm() {
  if (busy.value || stops.value.length) return
  busy.value = true
  error.value = ''
  try {
    const a = await api.channelWorkspaceMoveConfirm(props.channelId, body())
    const moveId = String(a?.move_id || '')
    busy.value = false
    if (!moveId) {
      error.value = hubCopy(a)
      return
    }
    confirmed.set(props.channelId, { moveId, topic: String(a?.topic || '') })
    await showStatus(moveId, String(a?.topic || ''))
  } catch (e) {
    busy.value = false
    await confirmRefused(e)
  }
}

/* 409 move_blocked: the plan again, its .blocked shown; 409 move_open: that
   move's status (one GO per move); anything else stays on the confirm */
async function confirmRefused(e: unknown) {
  const tok = (e && typeof e === 'object' && 'token' in e) ? String((e as { token?: unknown }).token || '') : ''
  if (tok === 'move_blocked') {
    await loadPlan()
    if (plan.value) screen.value = screenAfterPlan(plan.value)
    return
  }
  const open = openMoveId(e)
  if (open) {
    /* the 409 names no topic: this page's own click of that move knows it */
    const mine = confirmed.get(props.channelId)
    await showStatus(open, mine?.moveId === open ? mine.topic : '')
    return
  }
  error.value = hubCopy(e)
}

async function showStatus(moveId: string, topic: string) {
  screen.value = 'status'
  status.value = null
  statusGone.value = false
  if (topic) void topicLink(topic)
  try {
    status.value = await api.channelMoveStatus(moveId)
  } catch (e) {
    /* T17's route reads the journal in the page's workspace; from <SRC> a
       journal kept in <DST> answers 404 unknown_move (spec 169 9.x, open);
       any other failure (5xx, network) is an error, not that case */
    const code = (e && typeof e === 'object' && 'status' in e) ? Number((e as { status?: unknown }).status) : 0
    if (code === 404) statusGone.value = true
    else error.value = hubCopy(e)
  }
}

/* the GO's topic is in the operator workspace, the apex tenant (t1) */
async function topicLink(topic: string) {
  const path = `/t/${encodeURIComponent(topic)}`
  const apex = String(useRuntimeConfig().public.tenant || '')
  topicHref.value = (apex ? await tenantHostUrl(apex, path) : '') || path
}
</script>

<script lang="ts">
type Memo = Map<string, { moveId: string, topic: string }>
const memo: Memo = new Map()
function moveMemo(): Memo {
  return memo
}
</script>

<style scoped>
.cwm { display: grid; gap: 12px; }
.cwm__field { display: grid; gap: 4px; }
.cwm__head { margin: 0; font-size: 1rem; }
.cwm__list { margin: 0; padding-inline-start: 1.25rem; display: grid; gap: 4px; }
.cwm__line { overflow-wrap: anywhere; white-space: pre-wrap; }
.cwm__error { color: var(--color-danger); margin: 0; }
.cwm__actions { display: flex; justify-content: flex-end; gap: 12px; flex-wrap: wrap; }
</style>
