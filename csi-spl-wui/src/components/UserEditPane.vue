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
          <dd data-test="users-pane-invite-mailed">{{ invite.mailCount > 0 ? t('users.mailed_yes', { n: invite.mailCount }) : t('users.mailed_no') }}</dd>
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
          :data-test="invite.mailCount > 0 ? 'users-pane-resend' : 'users-pane-send-mail'"
          @click="sendMail"
        >
          {{ invite.mailCount > 0 ? t('users.resend') : t('users.send_invite_email') }}
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

      <p v-if="notice" class="users-notice" role="status" data-test="users-pane-notice">{{ notice }}</p>
      <p v-if="error" class="users-error" role="alert" data-test="users-pane-error">{{ error }}</p>
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
  </aside>
</template>

<script setup lang="ts">
import UiDialog from '~/components/UiDialog.vue'
import LocaleCombobox from '~/components/LocaleCombobox.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAuthClient } from '~/composables/useAuthClient'
import { useAccessStore } from '~/stores/access'
import { roleLabelKey, MEMBERS_IMPERSONATE } from '~/utils/access.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { inviteLink, memberLabel, userErrorKey, looksLikeEmail } from '~/utils/tenant-users.mjs'
import type { UserInvite, UserMember, UserRow } from '~/utils/tenant-users.mjs'

const props = defineProps<{
  /** The selected row; null with `creating` = the new-invite form. */
  row: UserRow | null
  creating: boolean
  roles: { id: string, grantable: boolean }[]
}>()
const emit = defineEmits<{
  close: []
  /** Something changed: reload the list and select `key` ('' = nothing). */
  changed: [key: string]
}>()

const { t, te, locale } = useI18n({ useScope: 'global' })
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
const profileDirty = computed(() => Boolean(member.value) && (profileName.value.trim() !== (member.value?.displayName || '') || profileLocale.value !== ''))
const busy = ref(false)
const error = ref('')
const notice = ref('')
const confirmOpen = ref(false)
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
  copied.value = false
  memberRole.value = member.value?.role || ''
  profileName.value = member.value?.displayName || ''
  profileLocale.value = ''
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
  try {
    await navigator.clipboard.writeText(link)
    copied.value = true
  } catch {
    copied.value = false
  }
}

function roleName(id: string) {
  const key = roleLabelKey(id)
  return key && te(key) ? t(key) : id
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

// CLE-77780: the explicit "Send the invite email" / "Resend" action — the only
// way an invite's mail goes out, always on a click. The mail rides the current
// invite; a 'sent' outcome says the relay took it, else it was stored only.
function sendMail() {
  const i = invite.value
  if (!i) return
  void run(async () => {
    const res = await api.inviteTenantUser({ email: i.email, role: i.role, locale: String(locale.value) })
    carry = res?.mail === 'sent' ? t('users.invited', { email: i.email }) : t('users.invite_saved_no_mail', { email: i.email })
    notice.value = carry
    emit('changed', i.key)
  })
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
