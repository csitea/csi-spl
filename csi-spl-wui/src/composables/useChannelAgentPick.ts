// r17-07: the channel dialog's agent pick, moved out of
// ChannelPropertiesDialog.vue.
//
// The refs stay declared in the dialog: its props.open watch resets and
// fills them, and the people functions share busy and error. The channel id
// is a getter so a changed prop is read on the next call.
import type { Ref } from 'vue'
import { channelFallbackLine, inviteErrorToken } from '~/utils/channel-members'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import type { useSpoolApi } from '~/composables/useSpoolApi'

type AgentRow = { id: string, box: string, online?: boolean, seated?: boolean, state?: string }
type ChosenAgent = { id: string, box: string, key: string }

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
}

export function useChannelAgentPick(o: AgentPickOpts) {
  const { api, channelId, busy, canAdd, error, agents, chosenAgent, agentQuery, fallback } = o

  function agentLabel(row: unknown) {
    if (!row || typeof row !== 'object') return ''
    const r = row as { id?: string, box?: string }
    if (!r.id) return ''
    return r.box ? `${r.id} ${r.box}` : r.id
  }

  function onAgentQuery(ev: Event) {
    const el = ev.target
    agentQuery.value = el instanceof HTMLInputElement ? el.value : ''
  }

  function onChooseAgent(row: ChosenAgent | null) {
    chosenAgent.value = row
    agentQuery.value = ''
  }

  async function addChosenAgent() {
    const row = chosenAgent.value
    if (!row || busy.value || !canAdd.value) return
    await pickAgent(row)
    if (agents.value.some((a) => a.id === row.id && a.box === row.box)) {
      chosenAgent.value = null
      agentQuery.value = ''
    }
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
    } catch (e) {
      error.value = inviteErrorToken(e)
    } finally {
      busy.value = false
    }
  }

  return { agentLabel, onAgentQuery, onChooseAgent, addChosenAgent, removeAgent, refreshAgentState, pickAgent }
}
