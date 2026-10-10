<!-- the edit form of one Users row, opened by a click on the row
     the way a message opens its topic pane (owner 2026-09-25: "when clicking
     on it ... the user edit form should appear"). Three shapes: a member
     (role, remove), a pending invite (revoke), and a new invite (email +
     role). Destructive actions confirm in a dialog first. The hub re-checks
     every call; `manageable` / `grantable` only decide what is offered. -->
<template>
  <aside
    class="users-pane"
    data-test="users-pane"
    :data-kind="mode"
    :aria-label="title"
  >
    <header class="users-pane__head">
      <MobileBack />
      <!-- SPL-1133: the X at the chosen corner (Mac = start, the default) -->
      <UiCloseButton side="start" class="icon-btn users-pane__close" data-test="users-pane-close" @click="emit('close')" />
      <h2 class="users-pane__title">{{ title }}</h2>
      <UiCloseButton side="end" class="icon-btn users-pane__close" data-test="users-pane-close" @click="emit('close')" />
    </header>
    <div class="users-pane__body">
      <!-- new invite -->
      <form v-if="mode === 'new'" class="users-form" data-test="users-invite-form" @submit.prevent="sendInvite">
        <label class="users-field">
          <span>{{ t('users.email') }}</span>
          <input
            ref="emailEl"
            v-model="email"
            type="email"
            autocomplete="off"
            required
            data-test="users-invite-email"
          >
        </label>
        <label class="users-field">
          <span>{{ t('users.role') }}</span>
          <select v-model="inviteRole" data-test="users-invite-role">
            <option v-for="r in grantable" :key="r.id" :value="r.id">{{ roleName(r.id) }}</option>
          </select>
        </label>
        <button type="submit" class="btn" :disabled="busy || !email.trim()" data-test="users-invite-send">
          {{ t('users.send_invite') }}
        </button>
      </form>

      <!-- a member -->
      <template v-else-if="member">
        <dl class="users-facts">
          <dt>{{ t('users.name') }}</dt>
          <dd data-test="users-pane-name">{{ member.displayName || '—' }}</dd>
          <dt>{{ t('users.email') }}</dt>
          <dd data-test="users-pane-email">{{ member.email || '—' }}</dd>
          <dt>{{ t('users.member_id') }}</dt>
          <dd><code data-test="users-pane-id">{{ member.humanId }}</code></dd>
          <dt>{{ t('users.since') }}</dt>
          <dd>{{ when(member.since) }}</dd>
          <dt>{{ t('users.last_seen') }}</dt>
          <dd data-test="users-pane-last-seen">{{ member.lastSeen ? when(member.lastSeen) : t('users.never') }}</dd>
          <!-- CLE-77778: who ordered this member's invite, and when -->
          <template v-if="member.orderedByName">
            <dt>{{ t('users.invited_by') }}</dt>
            <dd data-test="users-pane-ordered-by">{{ member.orderedByName }}<template v-if="member.orderedVia"> <span class="muted">{{ t('users.ordered_via') }} <code>{{ member.orderedVia }}</code></span></template></dd>
          </template>
          <template v-if="member.invitedOn">
            <dt>{{ t('users.invited_on') }}</dt>
            <dd data-test="users-pane-invited-on">{{ when(member.invitedOn) }}</dd>
          </template>
          <template v-if="member.suspended">
            <dt>{{ t('users.status') }}</dt>
            <dd data-test="users-pane-suspended">{{ t('users.suspended') }}</dd>
          </template>
          <!-- spec 072 A27: the membership's end of access -->
          <dt>{{ t('users.access_until') }}</dt>
          <dd data-test="users-pane-access-until">
            {{ member.accessUntil ? when(member.accessUntil) : t('users.access_no_end') }}<template v-if="member.accessEnded"> · {{ t('users.access_ended') }}</template>
          </dd>
        </dl>
        <p v-if="!member.manageable" class="muted users-note" data-test="users-pane-locked">
          {{ member.you ? t('users.not_manageable_self') : t('users.not_manageable_role') }}
        </p>
        <form class="users-form" @submit.prevent="saveRole">
          <label class="users-field">
            <span>{{ t('users.role') }}</span>
            <select v-model="memberRole" :disabled="!member.manageable || busy" data-test="users-pane-role">
              <option v-if="!roleKnown(member.role)" :value="member.role">{{ roleName(member.role) }}</option>
              <option v-for="r in roles" :key="r.id" :value="r.id" :disabled="!r.grantable">{{ roleName(r.id) }}</option>
            </select>
          </label>
          <button
            type="submit"
            class="btn"
            :disabled="!member.manageable || busy || memberRole === member.role"
            data-test="users-pane-save-role"
          >
            {{ t('users.save_role') }}
          </button>
        </form>
        <!-- specs/046: the profile of an account that is in this tenant alone
             (the hub answers 409 shared_account otherwise) -->
        <form v-if="member.manageable" class="users-form" data-test="users-profile-form" @submit.prevent="saveProfile">
          <label class="users-field">
            <span>{{ t('users.name') }}</span>
            <input v-model="profileName" type="text" maxlength="200" autocomplete="off" data-test="users-pane-name-input">
          </label>
          <div class="users-field">
            <span id="users-pane-locale-label">{{ t('users.language') }}</span>
            <LocaleCombobox v-model="profileLocale" test-prefix="users-pane-locale" labelled-by="users-pane-locale-label" />
          </div>
          <button type="submit" class="btn" :disabled="busy || !profileDirty" data-test="users-pane-save-profile">
            {{ t('users.save_profile') }}
          </button>
          <small class="muted">{{ t('users.profile_hint') }}</small>
        </form>
        <!-- spec 072 A27: access that ends on a date (the last day, local);
             past it the hub refuses the person here, the row stays -->
        <form v-if="member.manageable" class="users-form" data-test="users-access-form" @submit.prevent="saveAccess">
          <label class="users-field">
            <span>{{ t('users.access_until') }}</span>
            <input v-model="accessDay" type="date" data-test="users-pane-access-input">
          </label>
          <button type="submit" class="btn" :disabled="busy || !accessDay || accessDay === accessDateOf(member.accessUntil)" data-test="users-pane-save-access">
            {{ t('users.save_access') }}
          </button>
          <button
            v-if="member.accessUntil"
            type="button"
            class="btn ghost"
            :disabled="busy"
            data-test="users-pane-clear-access"
            @click="clearAccess"
          >
            {{ t('users.clear_access') }}
          </button>
          <small class="muted">{{ t('users.access_hint') }}</small>
        </form>
        <!-- t1 f265541a: the member's sign-in emails; the admin adds and
             removes as the hub allows, only the member confirms one -->
        <section class="users-emails" data-test="users-pane-emails">
          <h3 class="users-emails__title">{{ t('signin_emails.title') }}</h3>
          <SignInEmailsPanel :human-id="member.humanId" :self="member.you" :can-edit="member.manageable || member.you" />
        </section>
        <!-- specs/054: act as this member (a read-and-verify clone session) -->
        <button
          v-if="canActAs"
          type="button"
          class="btn"
          :disabled="busy"
          data-test="users-pane-act-as"
          @click="actAs"
        >
          {{ t('act_as.start', { name: member.displayName || member.humanId }) }}
        </button>
        <!-- t1 ea0af569: mail the member a one-time reset link (the admin never
             sees the password); greyed out, with the reason, for a member who
             signs in with an identity provider only -->
        <button
          v-if="reset.offered"
          type="button"
          class="btn ghost"
          :disabled="busy || !reset.enabled"
          :title="reset.enabled ? t('users.reset_password_hint') : resetReason"
          data-test="users-pane-reset-password"
          @click="openReset"
        >
          {{ t('users.reset_password') }}
        </button>
        <small v-if="reset.offered && !reset.enabled" class="muted users-note" data-test="users-pane-reset-password-reason">{{ resetReason }}</small>
        <button
          v-if="member.manageable"
          type="button"
          class="btn ghost"
          :disabled="busy"
          data-test="users-pane-suspend"
          @click="toggleSuspend"
        >
          {{ member.suspended ? t('users.restore') : t('users.suspend') }}
        </button>
        <button
          type="button"
          class="btn ghost users-danger"
          :disabled="!member.manageable || busy"
          data-test="users-pane-remove"
          @click="confirmOpen = true"
        >
          {{ t('users.remove') }}
        </button>
      </template>

      <!-- a pending invite -->
      <template v-else-if="invite">
        <dl class="users-facts">
          <dt>{{ t('users.email') }}</dt>
          <dd data-test="users-pane-email">{{ invite.email }}</dd>
          <dt>{{ t('users.role') }}</dt>
          <dd data-test="users-pane-invite-role">{{ roleName(invite.role) }}</dd>
          <dt>{{ t('users.invited_by') }}</dt>
          <dd data-test="users-pane-invite-ordered-by">
            <template v-if="invite.orderedByName">{{ invite.orderedByName }}</template>
            <code v-else>{{ invite.invitedBy }}</code>
            <template v-if="invite.orderedVia"> <span class="muted">{{ t('users.ordered_via') }} <code>{{ invite.orderedVia }}</code></span></template>
          </dd>
          <dt>{{ t('users.expires') }}</dt>
          <dd>{{ when(invite.expiresAt) }}<template v-if="invite.expired"> · {{ t('users.expired') }}</template></dd>
          <dt>{{ t('users.created') }}</dt>
          <dd data-test="users-pane-invite-created">{{ invite.createdAt ? when(invite.createdAt) : '—' }}</dd>
          <dt>{{ t('users.mailed') }}</dt>
          <!-- HUM-10: whether and WHEN the mail went out; a re-invite resets the count, not mailed_at -->
          <dd data-test="users-pane-invite-mailed">{{ invite.mailedAt ? t('users.mailed_at', { at: when(invite.mailedAt) }) : inviteMailed(invite) ? t('users.mailed_yes', { n: invite.mailCount }) : t('users.mailed_no') }}</dd>
        </dl>
        <!-- 047 W13: the way in when no mail arrived (a log-only relay, spam) -->
        <button
          v-if="linkOf(invite)"
          type="button"
          class="btn ghost"
          data-test="users-pane-copy-link"
          :data-link="linkOf(invite)"
          @click="copyLink(invite)"
        >
          {{ copied ? t('common.copied') : t('users.copy_link') }}
        </button>
        <small v-if="linkOf(invite)" class="muted users-note" data-test="users-pane-copy-link-hint">{{ t('users.copy_link_hint', { email: invite.email }) }}</small>
        <!-- CLE-77780: the ONE way an invite's mail goes out, always on a click.
             "Send the invite email" until it has been mailed, then "Resend". -->
        <button
          type="button"
          class="btn"
          :disabled="busy"
          :data-test="inviteMailed(invite) ? 'users-pane-resend' : 'users-pane-send-mail'"
          @click="sendMail"
        >
          {{ inviteMailed(invite) ? t('users.resend') : t('users.send_invite_email') }}
        </button>
        <button
          type="button"
          class="btn ghost users-danger"
          :disabled="busy"
          data-test="users-pane-revoke"
          @click="confirmOpen = true"
        >
          {{ t('users.revoke') }}
        </button>
      </template>

      <p v-if="notice" ref="noticeEl" class="users-notice" role="status" data-test="users-pane-notice">{{ notice }}</p>
      <p v-if="error" ref="errorEl" class="users-error" role="alert" data-test="users-pane-error">{{ error }}</p>
    </div>

    <UiDialog
      :open="confirmOpen"
      size="md"
      :title="member ? t('users.remove_confirm_title') : t('users.revoke_confirm_title')"
      @update:open="confirmOpen = $event"
    >
      <p data-test="users-confirm-text">
        {{ member ? t('users.remove_confirm', { name: memberLabel(member) }) : t('users.revoke_confirm', { email: invite?.email || '' }) }}
      </p>
      <template #footer>
        <button type="button" class="btn ghost" data-test="users-confirm-cancel" @click="confirmOpen = false">
          {{ t('common.cancel') }}
        </button>
        <button type="button" class="btn users-danger" :disabled="busy" data-test="users-confirm-ok" @click="destroy">
          {{ member ? t('users.remove') : t('users.revoke') }}
        </button>
      </template>
    </UiDialog>

    <UiDialog
      :open="resetOpen"
      size="md"
      :title="t('users.reset_confirm_title')"
      @update:open="resetOpen = $event"
    >
      <p data-test="users-reset-text">{{ t('users.reset_confirm', { name: member ? memberLabel(member) : '', email: member?.email || '' }) }}</p>
      <label class="users-check">
        <input v-model="resetSignOut" type="checkbox" data-test="users-reset-sign-out">
        <span>{{ t('users.reset_sign_out') }}</span>
      </label>
      <template #footer>
        <button type="button" class="btn ghost" data-test="users-reset-cancel" @click="resetOpen = false">
          {{ t('common.cancel') }}
        </button>
        <button type="button" class="btn" :disabled="busy" data-test="users-reset-ok" @click="resetPassword">
          {{ t('users.reset_send') }}
        </button>
      </template>
    </UiDialog>
  </aside>
</template>

<script setup lang="ts">
import { writeClipboard } from '~/utils/clipboard.mjs'
import UiDialog from '~/components/UiDialog.vue'
/* t1 f265541a: its own chunk, fetched when a member's pane opens */
const SignInEmailsPanel = defineAsyncComponent(() => import('~/components/SignInEmailsPanel.vue'))
import LocaleCombobox from '~/components/LocaleCombobox.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAuthClient } from '~/composables/useAuthClient'
import { useAccessStore } from '~/stores/access'
import { MEMBERS_IMPERSONATE } from '~/utils/access.mjs'
import { useRoleName } from '~/composables/useRoleName'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { accessDateOf, accessUntilOfDate, inviteLink, inviteMailed, mailOutcomeKey, memberLabel, openInviteFor, passwordResetState, userErrorKey, looksLikeEmail } from '~/utils/tenant-users.mjs'
import type { UserInvite, UserMember, UserRow } from '~/utils/tenant-users.mjs'

const props = defineProps<{
  /** The selected row; null with `creating` = the new-invite form. */
  row: UserRow | null
  creating: boolean
  roles: { id: string, grantable: boolean }[]
  /** The list's invites: the form opens an address's open invite instead of re-creating it. */
  invites?: UserInvite[]
}>()
const emit = defineEmits<{
  close: []
  /** Something changed: reload the list and select `key` ('' = nothing). */
  changed: [key: string]
}>()

const { t, locale } = useI18n({ useScope: 'global' })
const roleName = useRoleName()
const api = useSpoolApi()
const auth = useAuthClient()
const access = useAccessStore()
const localePath = useLocalePath()

// specs/054: offer "Act as" for a member the reader may impersonate. The hub
// enforces the permission AND the strict role ceiling; `manageable && !you`
// mirrors it in the UI (a peer/owner is neither manageable nor a valid target).
const canActAs = computed(() => Boolean(member.value && member.value.manageable && !member.value.you && access.can(MEMBERS_IMPERSONATE)))

const mode = computed(() => (props.creating ? 'new' : props.row?.kind || 'none'))
const member = computed(() => (!props.creating && props.row?.kind === 'member' ? props.row as UserMember : null))
const invite = computed(() => (!props.creating && props.row?.kind === 'invite' ? props.row as UserInvite : null))
const grantable = computed(() => props.roles.filter((r) => r.grantable))
const title = computed(() => {
  if (mode.value === 'new') return t('users.invite_title')
  if (invite.value) return t('users.edit_title_invite')
  return t('users.edit_title_member')
})

const email = ref('')
const inviteRole = ref('developer')
const memberRole = ref('')
const profileName = ref('')
const profileLocale = ref('')
const accessDay = ref('')
const profileDirty = computed(() => Boolean(member.value) && (profileName.value.trim() !== (member.value?.displayName || '') || profileLocale.value !== ''))
const busy = ref(false)
const error = ref('')
const notice = ref('')
const confirmOpen = ref(false)
/* t1 ea0af569: the Reset password confirmation; "sign them out everywhere" defaults ON */
const resetOpen = ref(false)
/* the outcome lines sit at the foot of a long pane: a reset scrolls its answer into view */
const noticeEl = ref<HTMLElement | null>(null)
const errorEl = ref<HTMLElement | null>(null)
const resetSignOut = ref(true)
const reset = computed(() => passwordResetState(member.value))
const resetReason = computed(() => t('users.reset_password_federated', { providers: reset.value.providers.join(', ') || '—' }))
const emailEl = ref<HTMLInputElement | null>(null)
const copied = ref(false)
/* A sent invite reopens the pane on its new row; the notice survives that switch. */
let carry = ''

// The watch runs immediately (immediate: true), so every ref it touches must be
// declared ABOVE it — `copied` used to sit below and threw "Cannot access
// 'copied' before initialization" on setup, so the member-edit pane never
// opened (pre-054; the e2e that catches it, users-admin, only runs in the
// often-cancelled quality gate).
watch(() => [props.row?.key, props.creating], () => {
  error.value = ''
  notice.value = carry
  carry = ''
  confirmOpen.value = false
  resetOpen.value = false
  copied.value = false
  memberRole.value = member.value?.role || ''
  profileName.value = member.value?.displayName || ''
  profileLocale.value = ''
  accessDay.value = accessDateOf(member.value?.accessUntil || '')
  if (props.creating) {
    email.value = ''
    const ids = grantable.value.map((r) => r.id)
    inviteRole.value = ids.includes('developer') ? 'developer' : (ids[0] || '')
    void nextTick(() => emailEl.value?.focus())
  }
}, { immediate: true })

/* the sign-in page of the tenant the list came from */
function linkOf(i: UserInvite | null) {
  return i && !i.expired && import.meta.client ? inviteLink(window.location.origin, i.tenant, i.email) : ''
}
async function copyLink(i: UserInvite | null) {
  const link = linkOf(i)
  if (!link) return
  copied.value = await writeClipboard(link)
}

function roleKnown(id: string) {
  return props.roles.some((r) => r.id === id)
}
function when(iso: string) {
  return isoDateTime(iso) || '—'
}
/** One place for every failure: the hub's token in words; a stale row reloads. */
function fail(e: unknown) {
  error.value = t(userErrorKey(e))
  const token = (e as { token?: string } | null)?.token
  if (token === 'role_changed' || token === 'not_found') emit('changed', props.row?.key || '')
}

async function run(job: () => Promise<void>) {
  if (busy.value) return
  busy.value = true
  error.value = ''
  notice.value = ''
  try {
    await job()
  } catch (e) {
    fail(e)
  } finally {
    busy.value = false
  }
}

function sendInvite() {
  const addr = email.value.trim()
  if (!looksLikeEmail(addr)) {
    error.value = t('users.error.bad_email')
    return
  }
  // HUM-10 2026-10-03: a second submit for an address with an open invite
  // re-created it, which reset its "sent" state, and said nothing. Open that
  // invite instead and say so; it carries Send/Resend and when it was mailed.
  const open = openInviteFor({ invites: props.invites || [] }, addr)
  if (open) {
    carry = open.mailedAt
      ? t('users.already_invited_mailed', { email: open.email, at: when(open.mailedAt) })
      : t('users.already_invited', { email: open.email })
    notice.value = carry
    emit('changed', open.key)
    return
  }
  void run(async () => {
    // CLE-77780: creating an invite never mails it. The owner does not want mail
    // sent on his behalf without a click; the admin sends it from this pane.
    await api.inviteTenantUser({ email: addr, role: inviteRole.value, locale: String(locale.value), noMail: true })
    const sent = addr.toLowerCase()
    carry = t('users.invite_saved_no_mail', { email: sent })
    notice.value = carry
    emit('changed', 'i:' + sent)
  })
}

function saveRole() {
  const m = member.value
  if (!m) return
  void run(async () => {
    await api.setTenantUserRole(m.humanId, memberRole.value, m.role)
    emit('changed', m.key)
    notice.value = t('users.role_saved')
  })
}

// specs/054: start acting as this member. On success THIS browser's cookie is
// the clone, so a full reload re-inits every store as the clone and the
// "Acting as X" banner shows. The hub 403s a target above the ceiling.
function actAs() {
  const m = member.value
  if (!m) return
  void run(async () => {
    const res = await auth.actAsStart(m.humanId)
    if (!res.ok) throw { token: res.error || 'unavailable' }
    if (import.meta.client) window.location.assign(localePath('/lobby'))
  })
}

function saveProfile() {
  const m = member.value
  if (!m) return
  const patch: { display_name?: string, locale?: string } = {}
  if (profileName.value.trim() !== m.displayName) patch.display_name = profileName.value.trim()
  if (profileLocale.value) patch.locale = profileLocale.value
  void run(async () => {
    await api.patchTenantUser(m.humanId, patch)
    emit('changed', m.key)
    notice.value = t('users.profile_saved')
  })
}

function toggleSuspend() {
  const m = member.value
  if (!m) return
  void run(async () => {
    await api.patchTenantUser(m.humanId, { disabled: !m.suspended })
    emit('changed', m.key)
    notice.value = m.suspended ? t('users.restored') : t('users.suspended_notice')
  })
}

// The reloaded row keeps its key, so the date follows its access_until here.
watch(() => member.value?.accessUntil, (v) => { accessDay.value = accessDateOf(v || '') })

// spec 072 A27: end the member's access here after the chosen local day.
function saveAccess() {
  const m = member.value
  const until = accessUntilOfDate(accessDay.value)
  if (!m || !until) return
  void run(async () => {
    await api.patchTenantUser(m.humanId, { access_until: until })
    emit('changed', m.key)
    notice.value = t('users.access_saved', { date: accessDay.value })
  })
}

function clearAccess() {
  const m = member.value
  if (!m) return
  void run(async () => {
    await api.patchTenantUser(m.humanId, { access_until: null })
    emit('changed', m.key)
    notice.value = t('users.access_cleared')
  })
}

// CLE-77780: the explicit "Send the invite email" / "Resend" action — the only
// way an invite's mail goes out, always on a click. The mail rides the current
// invite; a 'sent' outcome says the relay took it, else it was stored only.
function sendMail() {
  const i = invite.value
  if (!i) return
  void run(async () => {
    const res = await api.inviteTenantUser({ email: i.email, role: i.role, locale: String(locale.value) })
    // HUM-10: say what happened - sent, skipped as too soon after the last
    // mail (the hub keeps that one), or not sent - never a bare "saved".
    carry = t(mailOutcomeKey(res?.mail), { email: i.email, at: i.mailedAt ? when(i.mailedAt) : '—' })
    notice.value = carry
    emit('changed', i.key)
  })
}

function openReset() {
  resetSignOut.value = true
  resetOpen.value = true
}

// t1 ea0af569: the hub mails the member the reset link and, with sign-out,
// ends the old password and every session. The admin sees only the outcome.
function resetPassword() {
  const m = member.value
  if (!m) return
  const signOut = resetSignOut.value
  void run(async () => {
    const res = await api.resetTenantUserPassword(m.humanId, { signOut, locale: String(locale.value) })
    notice.value = t('users.reset_sent', { email: res?.email || m.email })
  }).then(() => nextTick(() => (noticeEl.value || errorEl.value)?.scrollIntoView({ block: 'center' })))
  resetOpen.value = false
}

function destroy() {
  const m = member.value
  const i = invite.value
  void run(async () => {
    if (m) await api.removeTenantUser(m.humanId)
    else if (i) await api.revokeTenantInvite(i.email)
    confirmOpen.value = false
    emit('changed', '')
  })
  confirmOpen.value = false
}
</script>

<style scoped>
.users-pane {
  flex: 0 0 var(--topic-w);
  width: var(--topic-w);
  max-width: 100%;
  min-width: 0;
  min-height: 0;
  display: flex;
  flex-direction: column;
  background: var(--color-bg);
  overflow: clip;
}
.users-pane__head {
  display: flex;
  align-items: center;
  gap: var(--spacing-sm);
  padding: 12px 16px;
  min-height: 52px;
  border-bottom: 1px solid var(--color-border);
}
.users-pane__title {
  flex: 1 1 auto;
  min-width: 0;
  margin: 0;
  font-size: 1rem;
  font-weight: 600;
  overflow-wrap: anywhere;
}
.users-pane__body {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  overflow-x: clip;
  padding: var(--spacing-md);
  display: flex;
  flex-direction: column;
  gap: var(--spacing-md);
}
.users-facts {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr);
  gap: 6px 12px;
  margin: 0;
}
.users-facts dt { color: var(--color-muted); }
.users-emails { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.users-emails__title { margin: 8px 0 0; font-size: 0.95rem; }
.users-facts dd { margin: 0; min-width: 0; overflow-wrap: anywhere; }
.users-form {
  display: flex;
  flex-direction: column;
  gap: var(--spacing-sm);
}
.users-field {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
}
.users-field input,
.users-field select {
  max-width: 100%;
  min-width: 0;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.users-danger {
  color: var(--color-danger);
  border-color: var(--color-danger);
}
.users-note { margin: 0; }
.users-check { display: flex; align-items: flex-start; gap: 8px; margin-top: var(--spacing-sm); }
.users-check input { margin-top: 3px; }
.users-notice { margin: 0; color: var(--color-ok); overflow-wrap: anywhere; }
.users-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
/* SPL-993: on a phone the pane is level 3 and MobileBack closes it, so the
   X goes; 44 px targets, 16 px fields (no iOS zoom), facts stacked. */
@media (max-width: 820px) {
  .users-pane__close { display: none; }
  .users-pane__body :deep(.icon-btn) { width: var(--tap, 44px); height: var(--tap, 44px); }
  .users-pane__body :deep(.btn) { min-height: var(--tap, 44px); }
  .users-field input,
  .users-field select { font-size: max(16px, 1rem); min-height: var(--tap, 44px); }
}
@media (max-width: 480px) {
  .users-facts { grid-template-columns: minmax(0, 1fr); }
  .users-facts dd + dt { margin-top: 8px; }
}
</style>
