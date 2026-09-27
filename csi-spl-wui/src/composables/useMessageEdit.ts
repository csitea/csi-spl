import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'
import { useChannelStore } from '~/stores/channel'
import { useTopicStore } from '~/stores/topic'
import { useLiveFeed } from '~/stores/live'
import { canEditMessage } from '~/utils/msg-edit.mjs'
import type { SpoolMessage } from '~/types/spool'

/**
 * CLE-3445 row E1 — who the viewer is, and the one call that saves an edit.
 *
 * WHY THE IDENTITY IS A CHAIN AND NOT A NEW PATH. Three places already know
 * who we are and none of them knows it in every mode, so this reads the
 * existing three in order of authority rather than adding a fourth:
 *
 *   1. `access.me.humanId` — GET /v1/view/me (specs/025 FR-008), the session's
 *      own answer and the one the hub will judge the PATCH by. It is null in
 *      the lde mock, where spool-client's me() returns null by design.
 *   2. `live.identity` — the WS welcome's `as`. This is the id a message sent
 *      from this browser is actually stamped with: stores/channel.ts builds
 *      its optimistic row with `from: live.identity.value`. So it is the value
 *      that will match `msg.from` even before /v1/view/me has answered.
 *   3. `roster.me.id` — the roster snapshot's `me`, which is what the lde mock
 *      supplies (HUM-1).
 *
 * The gate FAILS CLOSED: with no id at all, canEdit() is false and the `e`
 * shortcut is simply not offered. That is the opposite of utils/access.mjs,
 * which fails OPEN because it only hides buttons the hub re-checks. Here the
 * whole point is that a shortcut must never open an editor the hub will
 * refuse, so an unknown viewer gets no editor.
 */
export function useMessageEdit() {
  const api = useSpoolApi()
  const live = useLive()
  const access = useAccessStore()
  const roster = useRosterStore()

  const viewerId = computed(() => String(access.me?.humanId || live.identity.value || roster.me?.id || ''))
  const viewer = computed(() => ({ id: viewerId.value, box: String(roster.me?.box || '') }))

  /**
   * Author-only, no time window, and browser-authored — message-edit-v1 §4.
   *
   * Author-only is OWNER-STATED, 2026-09-22 ("of course msgs sent by bots
   * should not be editable"), not our inference; the no-time-window half is
   * CLE-00's ruling of the same day. Escape-cancels, over in
   * utils/msg-edit.mjs, stays INFERRED — the owner said nothing about it.
   *
   * CLE-3446: this predicate answers about a ROW, and it was never the thing
   * that was wrong. The bug was that a MessageCard outlived the row it was
   * mounted for, so a `false` here arrived at a card that was already holding
   * an open editor. The hosts key that mount by msg_id now, and MessageCard
   * resets its own edit state when the identity changes.
   */
  function canEdit(msg: SpoolMessage | null | undefined) {
    return canEditMessage(msg, viewer.value)
  }

  /**
   * Save. Resolves with the updated row, or REJECTS with the hub's own token
   * on `err.token` (not_author / not_found / empty_body / not_editable / …),
   * which utils/msg-edit.mjs editFailureKey() turns into a catalogue key.
   * Nothing on screen is touched here: the caller decides what to show, and
   * only once this has resolved (message-edit-v1 §5).
   */
  async function commit(msgId: string, body: string): Promise<SpoolMessage> {
    return api.editMessage(msgId, body)
  }

  /**
   * One edited row, applied to EVERY store that can be holding it.
   *
   * The same message is on screen in more than one place at once, and which
   * places depends on the route: the lobby feed and the pinned root of the
   * 3rd panel are the same message when that row's topic is open, and a
   * /channel row is the channel store's while the pane's root is the topic
   * store's. Measured on the mock harness before this existed: editing in the
   * 3rd panel updated the panel and left the feed behind it showing the OLD
   * body, because the pane told only the two stores it knew about.
   *
   * So the hosts stopped each picking their own subset. Every applyEdited
   * ignores a msg_id it does not hold (utils/msg-edit.mjs applyEdit), which
   * is what makes telling all of them both correct and cheap, and makes a
   * second application — the local emit and then the hub's `message_edited`
   * frame — idempotent rather than a double update.
   */
  function applyEverywhere(row: SpoolMessage) {
    useChannelStore().applyEdited(row)
    useLiveFeed('main').applyEdited(row)
    useLiveFeed('pane').applyEdited(row)
    useTopicStore().applyEditedRoot(row)
  }

  /**
   * Drop one message from every store that can be showing it. A delete in the
   * thread pane is also the middle-list card when that row is the opening
   * message, and the pinned root when the topic is message-rooted.
   */
  function dropEverywhere(msgId: string) {
    const id = String(msgId || '')
    if (!id) return
    useChannelStore().drop(id)
    useLiveFeed('main').drop(id)
    useLiveFeed('pane').drop(id)
    useTopicStore().dropRoot(id)
  }

  /** DELETE /v1/messages/{msg_id}, then drop the row. Rejects with the hub token. */
  async function removeMessage(msgId: string) {
    const id = String(msgId || '')
    await api.deleteMessage(id)
    dropEverywhere(id)
  }

  /**
   * CLE-35064: fold `srcId` into `keepId` with ONE hub call (the kept row
   * gets both bodies, the source is deleted, in one transaction), then show
   * both halves in every store at once. Rejects with the hub token and
   * changes nothing on screen.
   */
  async function mergeInto(srcId: string, keepId: string): Promise<SpoolMessage> {
    const row = await api.mergeMessage(String(srcId || ''), String(keepId || ''))
    applyEverywhere(row)
    dropEverywhere(String(srcId || ''))
    return row
  }

  return { viewer, viewerId, canEdit, commit, applyEverywhere, dropEverywhere, removeMessage, mergeInto }
}
