// r20-02: the channel dialog's people pick, moved out of
// ChannelPropertiesDialog.vue (the people twin of useChannelAgentPick).
//
// The refs stay declared in the dialog: its props.open watch resets and
// fills them, and the agent functions share busy and error. The props object
// is passed whole so a changed channelId is read on the next call.
import type { Ref } from 'vue'
import { inviteErrorToken } from '~/utils/channel-members'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import type { useSpoolApi } from '~/composables/useSpoolApi'
import type { useHumanNames } from '~/composables/useHumanNames'

interface PersonPickOpts {
  api: ReturnType<typeof useSpoolApi>
  props: { readonly channelId: string }
  people: ReturnType<typeof useHumanNames>
  busy: Ref<boolean>
  canAdd: Readonly<Ref<boolean>>
  error: Ref<string>
  selfId: Readonly<Ref<string>>
  localMembers: Ref<string[]>
  chosenPerson: Ref<string | null>
  personQuery: Ref<string>
}

export function useChannelPersonPick(o: PersonPickOpts) {
  const { api, props, people, busy, canAdd, error, selfId, localMembers, chosenPerson, personQuery } = o

  /** The chosen display name, else the bare HUM id (no box). */
  function personLabel(id: unknown) {
    return typeof id === 'string' && id ? people.label(id) : ''
  }

  function onPersonQuery(ev: Event) {
    const el = ev.target
    personQuery.value = el instanceof HTMLInputElement ? el.value : ''
  }

  function onChoosePerson(id: string | null) {
    chosenPerson.value = id
    personQuery.value = ''
  }

  async function addChosen() {
    const id = String(chosenPerson.value || '')
    if (!id || busy.value || !canAdd.value) return
    await pick(id)
    if (localMembers.value.includes(id)) {
      chosenPerson.value = null
      personQuery.value = ''
    }
  }

  async function removePerson(id: string) {
    if (busy.value || (!canAdd.value && id !== selfId.value)) return
    busy.value = true
    error.value = ''
    try {
      await withSessionRetry(api, () => api.removeChannelMember(props.channelId, id))
      localMembers.value = localMembers.value.filter((member) => member !== id)
    } catch (e) {
      error.value = inviteErrorToken(e)
    } finally {
      busy.value = false
    }
  }

  async function pick(id: string) {
    if (busy.value || !canAdd.value) return
    busy.value = true
    error.value = ''
    try {
      await withSessionRetry(api, () => api.addChannelMember(props.channelId, id))
      if (!localMembers.value.includes(id)) localMembers.value = [...localMembers.value, id]
    } catch (e) {
      error.value = inviteErrorToken(e)
    } finally {
      busy.value = false
    }
  }

  return { personLabel, onPersonQuery, onChoosePerson, addChosen, removePerson }
}
