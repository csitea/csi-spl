// r17-07: the channel dialog's agent pick, moved out of
// ChannelPropertiesDialog.vue.
//
// The refs stay declared in the dialog: its props.open watch resets and
// fills them, and the people functions share busy and error. The channel id
// is a getter so a changed prop is read on the next call.
import type { Ref } from 'vue'
import { channelFallbackLine, inviteErrorToken, type AgentKind } from '~/utils/channel-members'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import type { useSpoolApi } from '~/composables/useSpoolApi'

type AgentRow = { id: string, box: string, online?: boolean, seated?: boolean, state?: string }
// A picked row: an announced agent, or (kind, SPL-5000) a new agent of that kind.
type ChosenAgent = { id?: string, box?: string, kind?: string, key: string }

interface AgentPickOpts {
  api: ReturnType<typeof useSpoolApi>
  channelId: () => string
  busy: Ref<boolean>
  canAdd: Readonly<Ref<boolean>>
  error: Ref<string>
  agents: Ref<AgentRow[]>
  chosenAgent: Ref<ChosenAgent | null>
  agentQuery: Ref<string>
  fallback: Ref<ReturnType<typeof channelFallbackLine>>
  agentKinds: Ref<AgentKind[]>
  askedKind: Ref<string>
  kindLabel: (kind: string) => string
}

// An agent row's label: its id, then its box when it has one; a kind row's words.
function agentLabelOf(row: unknown, kindLabel: (kind: string) => string) {
  if (!row || typeof row !== 'object') return ''
  const r = row as { id?: string, box?: string, kind?: string }
  if (r.kind) return kindLabel(r.kind)
  if (!r.id) return ''
  return r.box ? `${r.id} ${r.box}` : r.id
}

// The query input, the choice and the remove: the steps that edit the list.
function agentEditSteps(o: AgentPickOpts) {
  const { api, channelId, busy, canAdd, error, agents, chosenAgent, agentQuery } = o

  function onAgentQuery(ev: Event) {
    const el = ev.target
    agentQuery.value = el instanceof HTMLInputElement ? el.value : ''
  }

  function onChooseAgent(row: ChosenAgent | null) {
    chosenAgent.value = row
    agentQuery.value = ''
  }

  async function removeAgent(row: { id: string, box: string }) {
    if (busy.value || !canAdd.value) return
    busy.value = true
    error.value = ''
    try {
      await withSessionRetry(api, () => api.removeChannelAgent(channelId(), row.id, row.box))
      agents.value = agents.value.filter((a) => !(a.id === row.id && a.box === row.box))
    } catch (e) {
      error.value = inviteErrorToken(e)
    } finally {
      busy.value = false
    }
  }

  return { onAgentQuery, onChooseAgent, removeAgent }
}

// SPL-5000: the kinds the list offers, and the ask for a new agent of one.
function agentKindSteps(o: AgentPickOpts) {
  const { api, channelId, busy, error, chosenAgent, agentQuery, agentKinds, askedKind } = o

  // No agent of the kind to pick, so the orchestrator is asked to start one and
  // seat it here. The row appears when the hub lists the seat.
  async function askForKind(kind: string) {
    busy.value = true
    error.value = ''
    try {
      await withSessionRetry(api, () => api.channelAgentKinds(channelId(), kind))
      askedKind.value = kind
      chosenAgent.value = null
      agentQuery.value = ''
    } catch (e) {
      error.value = inviteErrorToken(e)
    } finally {
      busy.value = false
    }
  }

  // Which kinds the list offers: a failure offers none, the dialog still works.
  async function loadAgentKinds() {
    try {
      const got = await withSessionRetry(api, () => api.channelAgentKinds(channelId()))
      agentKinds.value = Array.isArray(got.kinds) ? got.kinds : []
    } catch {
      agentKinds.value = []
    }
  }

  return { askForKind, loadAgentKinds }
}

// The add, the pick and the refresh: the steps that ask the hub for a new row.
function agentAddSteps(o: AgentPickOpts) {
  const { api, channelId, busy, canAdd, error, agents, chosenAgent, agentQuery, fallback } = o
  const { askForKind, loadAgentKinds } = agentKindSteps(o)

  async function addChosenAgent() {
    const row = chosenAgent.value
    if (!row || busy.value || !canAdd.value) return
    if (row.kind) {
      await askForKind(row.kind)
      return
    }
    const id = row.id || ''
    const box = row.box || ''
    await pickAgent({ id, box })
    if (agents.value.some((a) => a.id === id && a.box === box)) {
      chosenAgent.value = null
      agentQuery.value = ''
    }
  }

  // SPL-987: a picked agent's online / seated state is the hub's to say; read
  // the list again so the new row shows it (a failure keeps the row as it is).
  async function refreshAgentState() {
    try {
      const mem = await withSessionRetry(api, () => api.listChannelMembers(channelId()))
      const fresh = Array.isArray(mem.agents) ? mem.agents : []
      agents.value = agents.value.map((a) => fresh.find((f) => f.id === a.id && f.box === a.box) || a)
      fallback.value = channelFallbackLine((mem as { fallback?: unknown }).fallback)
    } catch {
      // the row stays without a state
    }
  }

  async function pickAgent(row: { id: string, box: string }) {
    if (busy.value || !canAdd.value) return
    busy.value = true
    error.value = ''
    try {
      await withSessionRetry(api, () => api.addChannelAgent(channelId(), row.id, row.box))
      if (!agents.value.some((a) => a.id === row.id && a.box === row.box)) {
        agents.value = [...agents.value, { id: row.id, box: row.box }]
      }
      void refreshAgentState()
      void loadAgentKinds()
    } catch (e) {
      error.value = inviteErrorToken(e)
    } finally {
      busy.value = false
    }
  }

  return { addChosenAgent, refreshAgentState, pickAgent, loadAgentKinds }
}

export function useChannelAgentPick(o: AgentPickOpts) {
  const { onAgentQuery, onChooseAgent, removeAgent } = agentEditSteps(o)
  const { addChosenAgent, refreshAgentState, pickAgent, loadAgentKinds } = agentAddSteps(o)
  const agentLabel = (row: unknown) => agentLabelOf(row, o.kindLabel)
  return { agentLabel, onAgentQuery, onChooseAgent, addChosenAgent, removeAgent, refreshAgentState, pickAgent, loadAgentKinds }
}
