// r20-02: the channel dialog's people pick, moved out of
// ChannelPropertiesDialog.vue (the people twin of useChannelAgentPick).
//
// The refs stay declared in the dialog: its props.open watch resets and
// fills them, and the agent functions share busy and error. The props object
// is passed whole so a changed channelId is read on the next call.
import type { Ref } from 'vue'
import { inviteEmail, inviteErrorToken } from '~/utils/channel-members'
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
  /** spec 025 section 11: addresses added before they joined the workspace. */
  localInvited: Ref<string[]>
  chosenPerson: Ref<string | null>
  personQuery: Ref<string>
}

// The label, the query input and the choice: the steps that ask the hub nothing.
function personInputSteps(o: PersonPickOpts) {
  const { people, chosenPerson, personQuery } = o

  /** The chosen display name, else the bare HUM id (no box); an address as typed. */
  function personLabel(id: unknown) {
    if (typeof id !== 'string' || !id) return ''
    return inviteEmail(id) ? id : people.label(id)
  }

  function onPersonQuery(ev: Event) {
    const el = ev.target
    personQuery.value = el instanceof HTMLInputElement ? el.value : ''
  }

  function onChoosePerson(id: string | null) {
    chosenPerson.value = id
    personQuery.value = ''
  }

  return { personLabel, onPersonQuery, onChoosePerson }
}

// The remove: one who may not add can still leave, and removes nobody else.
async function removePerson(o: PersonPickOpts, id: string) {
  const { api, props, busy, canAdd, error, selfId, localMembers, localInvited } = o
  if (busy.value || (!canAdd.value && id !== selfId.value)) return
  busy.value = true
  error.value = ''
  try {
    await withSessionRetry(api, () => api.removeChannelMember(props.channelId, id))
    localMembers.value = localMembers.value.filter((member) => member !== id)
    localInvited.value = localInvited.value.filter((email) => email !== id)
  } catch (e) {
    error.value = inviteErrorToken(e)
  } finally {
    busy.value = false
  }
}

// The add: an address goes to addByEmail, a HUM id joins as a member.
async function pick(o: PersonPickOpts, id: string) {
  const { api, props, busy, canAdd, error, localMembers } = o
  if (busy.value || !canAdd.value) return
  busy.value = true
  error.value = ''
  try {
    if (inviteEmail(id)) {
      await addByEmail(o, id)
    } else {
      await withSessionRetry(api, () => api.addChannelMember(props.channelId, id))
      if (!localMembers.value.includes(id)) localMembers.value = [...localMembers.value, id]
    }
  } catch (e) {
    error.value = inviteErrorToken(e)
  } finally {
    busy.value = false
  }
}

/** A member's address joins at once (human_id back); any other is pending. */
async function addByEmail(o: PersonPickOpts, email: string) {
  const { api, props, localMembers, localInvited } = o
  const res = await withSessionRetry(api, () => api.addChannelInvitee(props.channelId, email))
  const hum = res && typeof res.human_id === 'string' ? res.human_id : ''
  if (hum) {
    if (!localMembers.value.includes(hum)) localMembers.value = [...localMembers.value, hum]
    localInvited.value = localInvited.value.filter((e) => e !== email)
    return
  }
  if (!localInvited.value.includes(email)) localInvited.value = [...localInvited.value, email]
}

export function useChannelPersonPick(o: PersonPickOpts) {
  const { busy, canAdd, localMembers, localInvited, chosenPerson, personQuery } = o
  const { personLabel, onPersonQuery, onChoosePerson } = personInputSteps(o)

  // A refused add keeps the chosen person and the query, to try again.
  async function addChosen() {
    const id = String(chosenPerson.value || '')
    if (!id || busy.value || !canAdd.value) return
    await pick(o, id)
    if (localMembers.value.includes(id) || localInvited.value.includes(id)) {
      chosenPerson.value = null
      personQuery.value = ''
    }
  }

  return { personLabel, onPersonQuery, onChoosePerson, addChosen, removePerson: (id: string) => removePerson(o, id) }
}
