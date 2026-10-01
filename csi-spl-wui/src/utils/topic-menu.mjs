// csi-spl-wui/src/utils/topic-menu.mjs
//
// CLE-77891 (HUM-24, csitea topic af0ffb8c): every topic card's menu has the
// same shape. "On some topics the menu has only three options, on others more"
// - a member on someone else's topic saw Open / Copy link / Archive, the
// starter saw Edit, Move, Merge, Archive and Delete too. The hub's rules stay
// as they are (edit.go, message_move.go, topic_merge.go, topic_archive.go: the
// author, the tenant owner or an admin; archive per the workspace setting), so
// an entry the viewer may not use is SHOWN DISABLED with the reason, never
// hidden. Pure: the Node tests import it.
//
// topicMenuLocks answers, per entry, '' (allowed, or not this menu's to show)
// or the i18n key of the reason it is disabled. utils/msg-menu.mjs
// msgMenuItems({ locks }) draws a locked entry disabled with that reason.

import { isTopicCard, mayArchiveTopic, mayChangeTopic, TOPIC_ADMIN_ROLES } from './topic-archive.mjs'
import { isMovableTopic, mayMoveTopic } from './move.mjs'

const WHY = 'feed.msg_menu.why.'

/** The tenant owner or an admin (`me` is utils/access.mjs normalizeMe). */
function isModerator(me) {
  if (!me || typeof me !== 'object') return false
  return me.tenantOwner === true || TOPIC_ADMIN_ROLES.includes(String(me.role || ''))
}

/**
 * Why each topic-card entry is disabled for this viewer ('' = not locked).
 * `editable` is the caller's canEdit(msg) answer (utils/msg-edit.mjs, the
 * hub's edit rule), so Edit is locked exactly when the editor would refuse.
 *
 * @param {unknown} msg the topic card
 * @param {string} viewerId
 * @param {{ role?: string | null, tenantOwner?: boolean, topicArchivePolicy?: string } | null} me
 * @param {{ editable?: boolean, lobbyTaskId?: string }} [opts]
 * @returns {{ edit: string, move: string, merge: string, archive: string, delete: string }}
 */
export function topicMenuLocks(msg, viewerId, me, { editable = false, lobbyTaskId = '' } = {}) {
  const none = { edit: '', move: '', merge: '', archive: '', delete: '' }
  if (!isTopicCard(msg)) return none
  const m = /** @type {Record<string, unknown>} */ (msg)
  const out = { ...none }
  if (!editable) {
    /* a moderator may edit any HUMAN message: what is left is an agent's */
    out.edit = isModerator(me) ? WHY + 'edit_agent' : WHY + 'edit'
  }
  /* a topic-list stand-in (topic_row) is not a message: no Move entries at all */
  if (!m.topic_row && !mayMoveTopic(m, viewerId, me, lobbyTaskId)) {
    const place = isMovableTopic(m, lobbyTaskId) ? '' : WHY + 'move_place'
    out.move = place || WHY + 'move'
    out.merge = place || WHY + 'merge'
  }
  if (!mayArchiveTopic(m, viewerId, me)) {
    const policy = me && typeof me === 'object' ? me.topicArchivePolicy : ''
    out.archive = policy === 'admins' ? WHY + 'archive_admins' : WHY + 'archive_starter'
  }
  if (!mayChangeTopic(m, viewerId, me)) out.delete = WHY + 'delete'
  return out
}
