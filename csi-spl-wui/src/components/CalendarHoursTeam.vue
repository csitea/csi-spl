<!-- Spec 107 v1.2 T015 (sections 4.3, 4.4, 5.4; owner R11): the hours
     panel's Team tab, for a holder of hours.read. The members x days grid of
     the period holding the shown day (GET /v1/hours, T008: approved minutes
     only), totals per row and column, a member's per-target breakdown on a
     tap, its period state; filters member / kind / topic or issue. A holder
     of hours.approve gets Approve and Return (a required note) per frozen
     member, Approve all and Return all in the header (PUT /v1/hours/periods).
     Phone (<= 820 px): one card per member. Its own lazy chunk. -->
<template>
  <div class="hours-team" data-test="hours-team" :data-state="state" :data-layout="phone ? 'cards' : 'grid'">
    <p v-if="body" class="hours-team__period muted" data-test="hours-team-period" dir="ltr">{{ body.period?.start }} – {{ body.period?.end }}</p>
    <div class="hours-team__filters">
      <label class="hours-team__filter">
        <span class="muted">{{ t('hours_cal.team_filter_member') }}</span>
        <select v-model="filter.member" data-test="hours-team-filter-member">
          <option value="">{{ t('hours_cal.team_all') }}</option>
          <option v-for="m in members" :key="m.member_id" :value="m.member_id">{{ m.name || m.member_id }}</option>
        </select>
      </label>
      <label class="hours-team__filter">
        <span class="muted">{{ t('hours_cal.team_filter_kind') }}</span>
        <select v-model="filter.kind" data-test="hours-team-filter-kind">
          <option value="">{{ t('hours_cal.team_all') }}</option>
          <option v-for="k in HOURS_TEAM_KINDS" :key="k" :value="k">{{ t('hours_cal.kind_' + k) }}</option>
        </select>
      </label>
      <label v-if="topics.length" class="hours-team__filter">
        <span class="muted">{{ t('hours_cal.team_filter_issue') }}</span>
        <select v-model="filter.target" data-test="hours-team-filter-issue">
          <option value="">{{ t('hours_cal.team_all') }}</option>
          <option v-for="tp in topics" :key="tp" :value="tp">{{ nameOf(tp) }}</option>
        </select>
      </label>
    </div>
    <div v-if="canApprove" class="hours-team__all">
      <button type="button" class="btn" data-test="hours-team-approve-all" :disabled="busy || !grid.frozen" @click="decide('approve', [])">{{ t('hours_cal.team_approve_all') }}</button>
      <button type="button" class="btn ghost" data-test="hours-team-return-all" :disabled="busy || !grid.frozen" @click="askReturn('')">{{ t('hours_cal.team_return_all') }}</button>
    </div>
    <form v-if="returning !== null" class="hours-team__return" data-test="hours-team-return-form" :data-member="returning" @submit.prevent="sendReturn">
      <label class="hours-team__filter">
        <span>{{ returning ? t('hours_cal.team_return_one', { name: nameOfMember(returning) }) : t('hours_cal.team_return_all') }}</span>
        <textarea v-model="note" rows="2" maxlength="500" required data-test="hours-team-note" :placeholder="t('hours_cal.team_return_note')" />
      </label>
      <div class="hours-team__acts">
        <button type="submit" class="btn" data-test="hours-team-return-send" :disabled="busy || !note.trim()">{{ t('hours_cal.team_return') }}</button>
        <button type="button" class="btn ghost" data-test="hours-team-return-cancel" @click="returning = null">{{ t('common.cancel') }}</button>
      </div>
    </form>
    <p v-if="error" class="hours-team__error" role="alert" data-test="hours-team-error">{{ error }}</p>
    <p v-if="state === 'failed'" class="muted" role="alert" data-test="hours-team-failed">{{ t('hours_cal.load_failed') }}</p>
    <p v-else-if="state === 'ready' && !grid.rows.length" class="muted" data-test="hours-team-empty">{{ t('hours_cal.team_empty') }}</p>

    <ul v-if="phone" class="hours-team__cards">
      <li v-for="r in grid.rows" :key="r.member" class="hours-team__card" data-test="hours-team-row" :data-member="r.member" :data-state="r.state" :data-total="r.total">
        <button type="button" class="hours-team__who" data-test="hours-team-name" :aria-expanded="open === r.member ? 'true' : 'false'" @click="toggle(r.member)">
          <span class="hours-team__name">{{ r.name }}</span>
          <span class="hours-team__state muted" :data-state="r.state">{{ stateText(r.state) }}</span>
          <strong class="hours-team__num" dir="ltr">{{ hoursHhmm(r.total) }}</strong>
        </button>
        <p v-if="r.state === 'returned' && r.note" class="muted hours-team__note">{{ r.note }}</p>
        <div v-if="canApprove && r.state === 'frozen'" class="hours-team__acts">
          <button type="button" class="btn" data-test="hours-team-approve" :data-member="r.member" :disabled="busy" @click="decide('approve', [r.member])">{{ t('hours_cal.team_approve') }}</button>
          <button type="button" class="btn ghost" data-test="hours-team-return" :data-member="r.member" :disabled="busy" @click="askReturn(r.member)">{{ t('hours_cal.team_return') }}</button>
        </div>
        <ul v-if="open === r.member" class="hours-team__targets" data-test="hours-team-breakdown">
          <li v-for="x in r.targets" :key="x.target"><span>{{ nameOf(x.target) }}</span><span dir="ltr">{{ hoursHhmm(x.minutes) }}</span></li>
        </ul>
      </li>
    </ul>
    <div v-else-if="grid.rows.length" class="hours-team__scroll">
      <!-- each member is a tbody: its name line over its day cells, so the
           grid fits the panel's ~300 px without a name column -->
      <table class="hours-team__grid" data-test="hours-team-grid">
        <thead>
          <tr>
            <th v-for="c in shownCols" :key="c.day" scope="col" class="hours-team__daycol" :data-day="c.day">
              <span class="hours-team__wd">{{ t('calendar.weekdays.d' + calWeekday(c.day)) }}</span>
              <span dir="ltr">{{ Number(c.day.slice(8)) }}</span>
            </th>
            <th scope="col">{{ t('hours_cal.total') }}</th>
          </tr>
        </thead>
        <tbody v-for="r in grid.rows" :key="r.member" data-test="hours-team-row" :data-member="r.member" :data-state="r.state" :data-total="r.total">
          <tr>
            <th :colspan="shownCols.length + 1" scope="rowgroup" class="hours-team__namerow">
              <button type="button" class="hours-team__who" data-test="hours-team-name" :aria-expanded="open === r.member ? 'true' : 'false'" @click="toggle(r.member)">
                <span class="hours-team__name">{{ r.name }}</span>
                <span class="hours-team__state muted" :data-state="r.state">{{ stateText(r.state) }}</span>
              </button>
            </th>
          </tr>
          <tr>
            <td v-for="c in shownCols" :key="c.day" class="hours-team__cell" data-test="hours-team-cell" :data-day="c.day" dir="ltr">{{ r.cells[c.i] ? hoursHhmm(r.cells[c.i]) : '' }}</td>
            <td class="hours-team__cell hours-team__num" dir="ltr">{{ hoursHhmm(r.total) }}</td>
          </tr>
          <tr v-if="(canApprove && r.state === 'frozen') || (r.state === 'returned' && r.note)" class="hours-team__sub">
            <td :colspan="shownCols.length + 1">
              <p v-if="r.state === 'returned' && r.note" class="muted hours-team__note">{{ r.note }}</p>
              <div v-if="canApprove && r.state === 'frozen'" class="hours-team__acts">
                <button type="button" class="btn" data-test="hours-team-approve" :data-member="r.member" :disabled="busy" @click="decide('approve', [r.member])">{{ t('hours_cal.team_approve') }}</button>
                <button type="button" class="btn ghost" data-test="hours-team-return" :data-member="r.member" :disabled="busy" @click="askReturn(r.member)">{{ t('hours_cal.team_return') }}</button>
              </div>
            </td>
          </tr>
          <tr v-if="open === r.member" class="hours-team__sub">
            <td :colspan="shownCols.length + 1">
              <ul class="hours-team__targets" data-test="hours-team-breakdown">
                <li v-for="x in r.targets" :key="x.target"><span>{{ nameOf(x.target) }}</span><span dir="ltr">{{ hoursHhmm(x.minutes) }}</span></li>
              </ul>
            </td>
          </tr>
        </tbody>
        <tfoot>
          <tr><th :colspan="shownCols.length + 1" scope="rowgroup" class="hours-team__namerow">{{ t('hours_cal.total') }}</th></tr>
          <tr data-test="hours-team-totals" :data-total="grid.total">
            <td v-for="c in shownCols" :key="c.day" class="hours-team__cell" dir="ltr">{{ grid.cols[c.i] ? hoursHhmm(grid.cols[c.i]) : '' }}</td>
            <td class="hours-team__cell hours-team__num" dir="ltr">{{ hoursHhmm(grid.total) }}</td>
          </tr>
        </tfoot>
      </table>
    </div>
  </div>
</template>

<script setup lang="ts">
import { calWeekday } from '~/utils/calendar-year.mjs'
import { hoursHhmm, hoursIsWorkday, hoursTarget } from '~/utils/hours-calendar.mjs'
import { HOURS_TEAM_KINDS, hoursDecision, hoursTeamGrid, hoursTeamTopics } from '~/utils/hours-team.mjs'
import { decideTeamHours, loadTeamHours } from '~/utils/hours-team-api.mjs'
import { MOBILE_STACK_QUERY } from '~/utils/mobile-stack.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useViewerStore } from '~/stores/viewer'
import { useChannelStore } from '~/stores/channel'

type TeamBody = { period?: { start?: string, end?: string }, members?: { member_id: string, name?: string, state?: string, note?: string }[], entries?: { member_id: string, day: string, target: string, minutes: number }[] }

const props = defineProps<{ focus: string, today: string, canApprove: boolean }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const viewer = useViewerStore()
const channel = useChannelStore()

const body = shallowRef<TeamBody | null>(null)
const state = ref<'loading' | 'ready' | 'failed'>('loading')
const filter = reactive({ member: '', kind: '', target: '' })
const open = ref('')
const returning = ref<string | null>(null)
const note = ref('')
const busy = ref(false)
const error = ref('')

/* spec 5.4 / 10: one card per member at the calendar's phone width */
const phone = ref(false)
let mq: MediaQueryList | null = null
const onMq = () => { phone.value = Boolean(mq?.matches) }

let seq = 0
async function load() {
  const mine = ++seq
  state.value = 'loading'
  try {
    const got = await loadTeamHours(api, props.focus, props.today)
    if (mine !== seq) return
    body.value = got as TeamBody
    state.value = 'ready'
  } catch {
    if (mine === seq) state.value = 'failed'
  }
}
/* a new period (the shown day moved out of it) is a new read */
watch(() => props.focus, (d) => {
  const p = body.value?.period
  if (!p || d < String(p.start) || d > String(p.end)) void load()
})
onMounted(() => {
  mq = window.matchMedia(MOBILE_STACK_QUERY)
  onMq()
  mq.addEventListener('change', onMq)
  void load()
})
onBeforeUnmount(() => mq?.removeEventListener('change', onMq))

const members = computed(() => body.value?.members || [])
const topics = computed(() => hoursTeamTopics(body.value))
const grid = computed(() => hoursTeamGrid(body.value, filter))
/* a weekend column shows only when someone has hours on it: the grid fits the panel */
const shownCols = computed(() => grid.value.days.map((day, i) => ({ day, i })).filter((c) => hoursIsWorkday(c.day) || grid.value.cols[c.i] > 0))

const known = computed(() => {
  const out: Record<string, string> = {}
  for (const tp of viewer.topics as { task_id?: string, subject?: string }[]) {
    if (tp.task_id && tp.subject) out[`t:${tp.task_id}`] = tp.subject
  }
  for (const c of channel.channels) {
    if (c.channel_id && c.name) out[`ch:${c.channel_id}`] = `#${c.name}`
  }
  return out
})
function nameOf(target: string) {
  const v = hoursTarget(target, known.value)
  return v.label || t(v.kind === 'meeting' ? 'hours_cal.meeting' : 'hours_cal.other')
}
function nameOfMember(id: string) {
  return members.value.find((m) => m.member_id === id)?.name || id
}
function stateText(s: string) {
  return t('hours_cal.team_state_' + (['open', 'frozen', 'returned', 'approved'].includes(s) ? s : 'open'))
}
function toggle(member: string) {
  open.value = open.value === member ? '' : member
}
function askReturn(member: string) {
  returning.value = member
  note.value = ''
  error.value = ''
}

async function decide(action: 'approve' | 'return', who: string[], why = '') {
  const period = body.value?.period?.start
  if (!period || busy.value) return
  busy.value = true
  error.value = ''
  try {
    body.value = await decideTeamHours(api, hoursDecision(period, action, who, why), props.today) as TeamBody
    returning.value = null
    note.value = ''
  } catch (e) {
    const err = e as { status?: number, token?: string }
    error.value = err?.token === 'period_state' ? t('hours_cal.team_conflict') : t('hours_cal.team_failed')
    void load()
  } finally {
    busy.value = false
  }
}
function sendReturn() {
  if (!note.value.trim()) return
  void decide('return', returning.value ? [returning.value] : [], note.value)
}
</script>

<style scoped>
.hours-team { display: flex; flex-direction: column; gap: 8px; min-inline-size: 0; }
.hours-team__period { margin: 0; font-size: 0.75rem; }
.hours-team__filters { display: flex; flex-wrap: wrap; gap: 6px; }
.hours-team__filter { display: flex; flex-direction: column; gap: 2px; flex: 1 1 8rem; min-inline-size: 0; font-size: 0.75rem; }
.hours-team__filter select,
.hours-team__filter textarea { min-block-size: 44px; inline-size: 100%; font-size: 0.875rem; }
.hours-team__all,
.hours-team__acts { display: flex; flex-wrap: wrap; gap: 6px; }
.hours-team__all .btn,
.hours-team__acts .btn { min-block-size: 44px; }
.hours-team__return { display: flex; flex-direction: column; gap: 6px; padding: 8px; border-radius: var(--radius-sm); background: var(--color-selected); }
.hours-team__error { margin: 0; color: var(--color-danger); }
.hours-team__scroll { overflow-x: auto; min-inline-size: 0; }
.hours-team__grid { border-collapse: collapse; table-layout: fixed; inline-size: 100%; font-size: 0.75rem; font-variant-numeric: tabular-nums; }
.hours-team__grid th,
.hours-team__grid td { padding: 2px; border-block-end: 1px solid var(--color-border); text-align: end; white-space: nowrap; }
.hours-team__grid thead th { font-weight: 600; vertical-align: bottom; }
.hours-team__daycol span { display: block; }
.hours-team__wd { font-weight: 400; }
.hours-team__grid .hours-team__namerow { padding: 0; border-block-end: 0; text-align: start; white-space: normal; }
.hours-team__grid tfoot { font-weight: 600; }
.hours-team__grid tfoot td { border-block-end: 0; }
.hours-team__sub td { text-align: start; white-space: normal; }
.hours-team__num { font-weight: 600; }
.hours-team__who {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  inline-size: 100%;
  min-block-size: 44px;
  padding: 2px 0;
  border: 0;
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: start;
  cursor: pointer;
}
.hours-team__namerow .hours-team__who { flex-direction: row; align-items: center; gap: 8px; }
.hours-team__name { font-weight: 600; overflow-wrap: anywhere; }
.hours-team__state { font-size: 0.7rem; }
.hours-team__note { margin: 0; font-size: 0.75rem; }
.hours-team__targets { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; font-size: 0.75rem; }
.hours-team__targets li { display: flex; justify-content: space-between; gap: 8px; }
.hours-team__targets li span:first-child { overflow-wrap: anywhere; min-inline-size: 0; }
.hours-team__cards { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
.hours-team__card { display: flex; flex-direction: column; gap: 6px; padding: 8px; border: 1px solid var(--color-border); border-radius: var(--radius-sm); }
.hours-team__card .hours-team__who { display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; column-gap: 8px; }
.hours-team__card .hours-team__state { grid-column: 1; }
.hours-team__card .hours-team__num { grid-column: 2; grid-row: 1 / span 2; font-size: 1rem; }
</style>
