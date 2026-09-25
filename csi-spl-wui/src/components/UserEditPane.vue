<!-- CLE-34969: the edit form of one Users row, opened by a click on the row
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
      <h2 class="users-pane__title">{{ title }}</h2>
      <button
        type="button"
        class="icon-btn"
        data-test="users-pane-close"
        :title="t('common.close')"
        :aria-label="t('common.close')"
        @click="emit('close')"
      >
        <UiIcon name="x" :size="18" />
      </button>
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
          <dd><code>{{ invite.invitedBy }}</code></dd>
          <dt>{{ t('users.expires') }}</dt>
          <dd>{{ when(invite.expiresAt) }}<template v-if="invite.expired"> · {{ t('users.expired') }}</template></dd>
        </dl>
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
import { useSpoolApi } from '~/composables/useSpoolApi'
import { roleLabelKey } from '~/utils/access.mjs'
import { memberLabel, userErrorKey, looksLikeEmail } from '~/utils/tenant-users.mjs'
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
const busy = ref(false)
const error = ref('')
const notice = ref('')
const confirmOpen = ref(false)
const emailEl = ref<HTMLInputElement | null>(null)

watch(() => [props.row?.key, props.creating], () => {
  error.value = ''
  notice.value = ''
  confirmOpen.value = false
  memberRole.value = member.value?.role || ''
  if (props.creating) {
    email.value = ''
    const ids = grantable.value.map((r) => r.id)
    inviteRole.value = ids.includes('developer') ? 'developer' : (ids[0] || '')
    void nextTick(() => emailEl.value?.focus())
  }
}, { immediate: true })

function roleName(id: string) {
  const key = roleLabelKey(id)
  return key && te(key) ? t(key) : id
}
function roleKnown(id: string) {
  return props.roles.some((r) => r.id === id)
}
function when(iso: string) {
  const d = new Date(iso)
  if (!iso || Number.isNaN(d.getTime())) return '—'
  try {
    return d.toLocaleString(String(locale.value), { dateStyle: 'medium', timeStyle: 'short' })
  } catch {
    return d.toISOString()
  }
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
    const res = await api.inviteTenantUser({ email: addr, role: inviteRole.value, locale: String(locale.value) })
    const sent = addr.toLowerCase()
    emit('changed', 'i:' + sent)
    notice.value = res?.mail === 'sent' ? t('users.invited', { email: sent }) : t('users.invite_saved_no_mail', { email: sent })
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
</style>
