<!-- CLE-34969: the admin's Users list + edit pane (specs/025 FR-012), shared
     by /users and Tenant settings -> Members (SPL-1037, specs/046: `embedded`). The owner
     (2026-09-25): "the users should work similarly to the messages ... each
     of the users should be listed and when clicking on it ... the user edit
     form should appear". One row per member and per pending invite, like a
     feed; a click opens UserEditPane beside the list. USER_PANE_SIDE is the
     one switch for which side. The sidebar shows the entry only for
     members.invite; the hub answers 403 to anyone else on every route. -->
<template>
  <div
    class="users-page"
    :class="['users-page--pane-' + USER_PANE_SIDE, { 'users-page--pane-open': paneOpen && dir, 'users-page--embedded': embedded }]"
    data-test="users-page"
  >
    <div class="feed-col users-col">
      <header :class="embedded ? 'users-toolbar' : 'feed-header'">
        <template v-if="!embedded">
          <MobileBack />
          <h2>{{ t('users.title') }}</h2>
        </template>
        <span class="users-spacer" />
        <button
          v-if="dir"
          type="button"
          class="btn"
          data-test="users-invite-open"
          @click="startInvite"
        >
          {{ t('users.invite') }}
        </button>
      </header>
      <div class="feed-body users-body">
        <p v-if="loading && !dir" class="muted" aria-live="polite" data-test="users-loading">{{ t('users.loading') }}</p>
        <p v-else-if="denied" class="muted" role="alert" data-test="users-forbidden">{{ t('users.forbidden') }}</p>
        <p v-else-if="loadError" class="users-load-error" role="alert" data-test="users-error">{{ loadError }}</p>
        <template v-else-if="dir">
          <section class="users-group" aria-labelledby="users-members-h">
            <h3 id="users-members-h" class="users-group__title">{{ t('users.members', { n: dir.members.length }) }}</h3>
            <ul class="users-list" data-test="users-members">
              <li v-for="m in dir.members" :key="m.key">
                <button
                  type="button"
                  class="users-row"
                  :class="{ 'users-row--selected': selectedKey === m.key && !creating }"
                  :aria-pressed="selectedKey === m.key && !creating ? 'true' : 'false'"
                  data-test="users-row"
                  :data-key="m.key"
                  @click="select(m.key)"
                >
                  <SpoolAvatar :id="m.humanId" :size="32" />
                  <span class="users-row__main">
                    <span class="users-row__name">
                      {{ memberLabel(m) }}
                      <span v-if="m.you" class="users-tag">{{ t('users.you') }}</span>
                      <span v-if="m.disabled" class="users-tag">{{ t('users.disabled') }}</span>
                      <span v-if="m.suspended" class="users-tag" data-test="users-row-suspended">{{ t('users.suspended') }}</span>
                    </span>
                    <span v-if="m.email && m.email !== memberLabel(m)" class="users-row__sub muted">{{ m.email }}</span>
                  </span>
                  <span class="users-role" data-test="users-row-role">{{ roleName(m.role) }}</span>
                </button>
              </li>
            </ul>
          </section>
          <section class="users-group" aria-labelledby="users-invites-h">
            <h3 id="users-invites-h" class="users-group__title">{{ t('users.invites', { n: dir.invites.length }) }}</h3>
            <p v-if="!dir.invites.length" class="muted users-empty">{{ t('users.no_invites') }}</p>
            <ul v-else class="users-list" data-test="users-invites">
              <li v-for="i in dir.invites" :key="i.key">
                <button
                  type="button"
                  class="users-row"
                  :class="{ 'users-row--selected': selectedKey === i.key && !creating }"
                  :aria-pressed="selectedKey === i.key && !creating ? 'true' : 'false'"
                  data-test="users-row"
                  :data-key="i.key"
                  @click="select(i.key)"
                >
                  <UiIcon name="user" :size="20" />
                  <span class="users-row__main">
                    <span class="users-row__name">{{ i.email }}</span>
                    <span class="users-row__sub muted" data-test="users-invite-sub">{{ i.expired ? t('users.expired') : t('users.pending') }} · {{ i.mailCount > 0 ? t('users.mailed_short') : t('users.not_mailed_short') }}<template v-if="i.createdAt"> · {{ isoDate(i.createdAt) }}</template></span>
                  </span>
                  <span class="users-role" data-test="users-row-role">{{ roleName(i.role) }}</span>
                </button>
              </li>
            </ul>
          </section>
          <p v-if="!paneOpen" class="muted users-empty">{{ t('users.select_hint') }}</p>
        </template>
      </div>
    </div>
    <UserEditPane
      v-if="paneOpen && dir"
      :row="selected"
      :creating="creating"
      :roles="dir.roles"
      @close="closePane"
      @changed="reload"
    />
  </div>
</template>

<script setup lang="ts">
import SpoolAvatar from '~/components/SpoolAvatar.vue'
import UserEditPane from '~/components/UserEditPane.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { useMobileStack } from '~/composables/useMobileStack'
import { useRoleName } from '~/composables/useRoleName'
import { isoDate } from '~/utils/date-iso.mjs'
import { USER_PANE_SIDE, memberLabel, normalizeDirectory, userErrorKey } from '~/utils/tenant-users.mjs'
import type { UserRow } from '~/utils/tenant-users.mjs'

const props = withDefaults(defineProps<{
  /** Inside Tenant settings: no page header, and on a phone the edit pane is an overlay over the section. */
  embedded?: boolean
}>(), { embedded: false })

const { t } = useI18n({ useScope: 'global' })
const roleName = useRoleName()
const api = useSpoolApi()
const session = useSessionStore()

const dir = ref<ReturnType<typeof normalizeDirectory> | null>(null)
const loading = ref(false)
const denied = ref(false)
const loadError = ref('')
const selectedKey = ref('')
const creating = ref(false)

const rows = computed<UserRow[]>(() => (dir.value ? [...dir.value.members, ...dir.value.invites] : []))
const selected = computed(() => rows.value.find((r) => r.key === selectedKey.value) || null)
const paneOpen = computed(() => creating.value || Boolean(selected.value))

async function load() {
  loading.value = true
  try {
    dir.value = normalizeDirectory(await api.listTenantUsers())
    denied.value = false
    loadError.value = ''
  } catch (e) {
    const status = (e as { status?: number } | null)?.status
    denied.value = status === 403
    if (!denied.value) loadError.value = t(userErrorKey(e))
    dir.value = null
  } finally {
    loading.value = false
  }
}

function select(key: string) {
  creating.value = false
  selectedKey.value = key
}
function startInvite() {
  selectedKey.value = ''
  creating.value = true
}
function closePane() {
  creating.value = false
  selectedKey.value = ''
}
/* SPL-993: on a phone the edit pane is level 3, full width over the list;
   Back (chevron, swipe, browser) closes it */
const stack = useMobileStack()
if (props.embedded) stack.overlay(() => stack.isMobile.value && paneOpen.value && Boolean(dir.value), closePane)
else stack.rightPanel(() => stack.isMobile.value && paneOpen.value && Boolean(dir.value), closePane)
/** After a write: reload, then keep the pane on `key` when that row still exists. */
async function reload(key: string) {
  await load()
  if (key && rows.value.some((r) => r.key === key)) {
    creating.value = false
    selectedKey.value = key
  } else if (!creating.value || !key) {
    if (!rows.value.some((r) => r.key === selectedKey.value)) selectedKey.value = ''
    if (!key) creating.value = false
  }
}

watch(() => session.state, (st) => {
  if (st === 'in' || api.mock) void load()
}, { immediate: true })
</script>

<style scoped>
.users-page {
  display: flex;
  flex-direction: row;
  flex: 1 1 auto;
  min-width: 0;
  min-height: 0;
  height: 100%;
  max-width: 100%;
  overflow: clip;
}
/* USER_PANE_SIDE: 'left' puts the pane between the sidebar and the list. */
.users-page--pane-left { flex-direction: row-reverse; }
.users-page--pane-right > .users-pane { border-inline-start: 1px solid var(--color-border); }
.users-page--pane-left > .users-pane { border-inline-end: 1px solid var(--color-border); }
.users-spacer { flex: 1 1 auto; }
/* specs/046: inside Tenant settings the section is the page; the list and
   the pane sit side by side in it, with no page header. */
.users-page--embedded {
  height: auto;
  min-height: 420px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md, 12px);
  background: var(--color-bg-2);
}
.users-page--embedded .users-col { flex: 1 1 auto; min-width: 0; }
.users-toolbar { display: flex; align-items: center; gap: var(--spacing-sm); padding: 10px 16px 0; }
.users-body { padding: var(--spacing-sm) 0; }
.users-group__title {
  margin: var(--spacing-md) 20px var(--spacing-xs);
  font-size: 0.8125rem;
  font-weight: 600;
  color: var(--color-muted);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.users-list { list-style: none; margin: 0; padding: 0; }
.users-row {
  display: flex;
  align-items: center;
  gap: 12px;
  width: 100%;
  min-width: 0;
  padding: 8px 20px;
  border: 0;
  border-inline-start: var(--select-bar-w) solid transparent;
  background: transparent;
  color: var(--color-fg);
  text-align: start;
}
.users-row:hover { background: var(--color-surface-hover); }
.users-row--selected {
  background: var(--color-surface);
  border-inline-start-color: var(--color-accent);
}
.users-row__main {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
}
.users-row__name,
.users-row__sub {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.users-row__sub { font-size: 0.8125rem; }
.users-tag {
  margin-inline-start: 6px;
  padding: 0 6px;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-pill);
  font-size: 0.75rem;
  color: var(--color-muted);
}
.users-role {
  flex: 0 0 auto;
  font-size: 0.8125rem;
  color: var(--color-muted);
}
.users-empty { margin: var(--spacing-xs) 20px; }
.users-load-error { margin: var(--spacing-md) 20px; color: var(--color-danger); }
/* SPL-993: phones and small tablets show ONE of the two: the list, or the
   open edit pane full width (useMobileStack level 3). */
@media (max-width: 820px) {
  .users-page--pane-open > .users-col { display: none; }
  .users-page--pane-open > .users-pane { flex: 1 1 auto; width: 100%; border-inline: 0; }
  .users-row { min-height: var(--tap, 44px); }
}
</style>
