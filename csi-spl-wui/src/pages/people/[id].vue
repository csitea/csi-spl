<!-- CLE-77794 (owner 2026-09-30, topic 1fc29f99): a tenant member's card - the
     "small info on the right side" the People section opens. Avatar, name,
     owner/member, last seen and their free-text interests (humans.interests,
     rdb 0086), read from /v1/view/roster. A Message button opens the DM. -->
<template>
  <div class="feed-col" data-test="person-page">
    <header class="feed-header">
      <MobileBack />
      <h2 class="person-head">
        <SpoolAvatar :id="humanId" box="box-wui" :size="26" />
        <HumanName :id="humanId" box="box-wui" />
      </h2>
    </header>
    <div class="feed-body">
      <div class="person-card" data-test="person-card">
        <div class="person-card__hero">
          <SpoolAvatar :id="humanId" box="box-wui" :size="64" />
          <div class="person-card__heroText">
            <p class="person-card__name"><HumanName :id="humanId" box="box-wui" /></p>
            <p class="person-card__status" data-test="person-status">
              <span class="status-dot" :class="[{ on: online }, manual ? 'dot--' + manual.ring : '']" aria-hidden="true" />
              {{ online ? t('people.online') : t('people.offline') }}
            </p>
            <!-- spec 096 §5: the full manual status - state, until, note -->
            <p v-if="manual" class="person-card__manual" data-testid="person-manual-status">{{ manual.full }}</p>
          </div>
        </div>
        <dl class="person-card__facts">
          <dt>{{ t('people.role') }}</dt>
          <dd data-test="person-role">{{ isOwner ? t('people.owner') : t('people.member') }}</dd>
          <dt>{{ t('people.last_seen') }}</dt>
          <dd data-test="person-last-seen">{{ lastSeen }}</dd>
          <dt>{{ t('settings.member_id') }}</dt>
          <dd><code>{{ humanId }}</code></dd>
        </dl>
        <section class="person-card__interests">
          <h3>{{ t('people.interests') }}</h3>
          <p v-if="interests" class="person-card__interestsText" data-test="person-interests">{{ interests }}</p>
          <p v-else class="muted" data-test="person-interests-empty">{{ t('people.no_interests') }}</p>
        </section>
        <!-- CLE-77799 (owner 6da1d88e): one action row, same-size buttons with
             icon + label + a tooltip each. Message is the primary; Activity log
             (admin-only, audit.read) and Remove (admin-only) are secondary
             ghost buttons, Remove in a readable danger style (outline red text,
             not red-on-red). Removal reuses DELETE /v1/members/<id>; the hub
             re-checks self / last-owner / role-coverage and is the authority. -->
        <div v-if="hasActions" class="person-card__actions">
          <button v-if="!isSelf" type="button" class="btn person-card__act" data-test="person-message" :title="t('people.message')" @click="message">
            <UiIcon name="messages" :size="16" /><span>{{ t('people.message') }}</span>
          </button>
          <!-- t1 ea0af569 (B): on the reader's OWN card only, password sign-ins
               only; opens Settings -> Sign-in and security -->
          <NuxtLink v-if="canChangePassword" :to="localePath(CHANGE_PASSWORD_PATH)" class="btn ghost person-card__act" data-test="person-change-password" :title="t('user_menu.change_password')">
            <UiIcon name="lock" :size="16" /><span>{{ t('user_menu.change_password') }}</span>
          </NuxtLink>
          <button v-if="canSeeActivity" type="button" class="btn ghost person-card__act" data-test="person-activity-open" :title="t('activity.open_hint')" @click="activityOpen = true">
            <UiIcon name="history" :size="16" /><span>{{ t('activity.open') }}</span>
          </button>
          <button v-if="canRemove" type="button" class="btn ghost danger person-card__act" data-test="person-remove" :title="t('people.remove_hint')" @click="confirmOpen = true">
            <UiIcon name="trash" :size="16" /><span>{{ t('people.remove') }}</span>
          </button>
        </div>
        <p v-if="removeError" class="person-card__error" role="alert" data-test="person-remove-error">{{ removeError }}</p>
      </div>
    </div>

    <PersonActivityDialog v-model:open="activityOpen" :human-id="humanId" />

    <UiDialog :open="confirmOpen" size="md" :title="t('people.remove_confirm_title')" @update:open="confirmOpen = $event">
      <p data-test="person-remove-text">{{ t('people.remove_confirm', { name: personName }) }}</p>
      <template #footer>
        <button type="button" class="btn ghost" data-test="person-remove-cancel" @click="confirmOpen = false">{{ t('common.cancel') }}</button>
        <button type="button" class="btn danger" :disabled="removing" data-test="person-remove-ok" @click="removeMember">{{ t('people.remove') }}</button>
      </template>
    </UiDialog>
  </div>
</template>

<script setup lang="ts">
import UiDialog from '~/components/UiDialog.vue'
import PersonActivityDialog from '~/components/PersonActivityDialog.vue'
import { useRosterStore } from '~/stores/roster'
import { useHumanStatusStore } from '~/stores/human-status'
import { useAccessStore } from '~/stores/access'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useHumanNames } from '~/composables/useHumanNames'
import { canRemoveMember } from '~/utils/access.mjs'
import { userErrorKey } from '~/utils/tenant-users.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { CHANGE_PASSWORD_PATH, changePasswordOffered } from '~/utils/user-menu.mjs'
import { useSessionStore } from '~/stores/session'

const route = useRoute()
const roster = useRosterStore()
const access = useAccessStore()
const api = useSpoolApi()
const names = useHumanNames()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })

const humanId = computed(() => decodeURIComponent(String(route.params.id || '')))
const detail = computed(() => roster.humansDetail[humanId.value] || { owner: false, interests: '', last_seen: '' })
const isOwner = computed(() => detail.value.owner || roster.owners.includes(humanId.value))
const interests = computed(() => String(detail.value.interests || '').trim())
const online = computed(() => roster.isOnline(humanId.value, 'box-wui'))
const manual = computed(() => useHumanStatusStore().statusLabel(humanId.value, t))
const isSelf = computed(() => roster.self?.id === humanId.value)
const lastSeen = computed(() => (detail.value.last_seen ? isoDateTime(detail.value.last_seen) : t('people.never_seen')))
const personName = computed(() => names.label(humanId.value, 'box-wui') || humanId.value)

/* CLE-77799: the "Remove from workspace" action, for tenant admins/owners only
   (members.invite), never on the reader or the last owner. The hub re-checks. */
const canRemove = computed(() => canRemoveMember(access.me, {
  targetId: humanId.value,
  selfId: roster.self?.id,
  targetIsOwner: isOwner.value,
  ownerCount: roster.owners.length,
}))
const confirmOpen = ref(false)
const removing = ref(false)
const removeError = ref('')

/* CLE-77799: the admin-only Activity log (audit.read), a dialog off the card. */
const canSeeActivity = computed(() => access.can('audit.read'))
const activityOpen = ref(false)
/* the action row shows only when there is at least one action for this reader. */
/* t1 ea0af569 (B): "Change password" on the reader's own card, same rule as the account menu. */
const session = useSessionStore()
const canChangePassword = computed(() => isSelf.value && changePasswordOffered(session.claims, access.me?.actAs))
const hasActions = computed(() => !isSelf.value || canSeeActivity.value || canRemove.value || canChangePassword.value)

/* the roster is already loaded for the DM list; refresh once so a deep link
   straight to this card (no sidebar visited yet) still has the detail. The
   reader's role/permission (for the remove action) is read once here too. */
onMounted(() => {
  if (!roster.humansDetail[humanId.value]) void roster.refresh()
  void access.load()
})

function message() {
  void navigateTo(localePath('/dm/' + encodeURIComponent(humanId.value + '@box-wui')))
}

async function removeMember() {
  if (removing.value) return
  removing.value = true
  removeError.value = ''
  try {
    await api.removeTenantUser(humanId.value)
    confirmOpen.value = false
    await navigateTo(localePath('/people'))
  } catch (e) {
    removeError.value = t(userErrorKey(e))
  } finally {
    removing.value = false
  }
}
</script>

<style scoped>
.person-head { display: flex; align-items: center; gap: 8px; min-width: 0; }
.person-head :deep(.spool-avatar) { border-radius: 50%; flex-shrink: 0; }
.person-card { padding: 16px; max-width: 640px; display: flex; flex-direction: column; gap: 18px; min-width: 0; }
.person-card__hero { display: flex; align-items: center; gap: 14px; min-width: 0; }
.person-card__hero :deep(.spool-avatar) { border-radius: 50%; flex-shrink: 0; }
.person-card__heroText { min-width: 0; }
.person-card__name { margin: 0; font-size: 1.1rem; font-weight: 700; overflow-wrap: anywhere; }
.person-card__status { margin: 4px 0 0; display: flex; align-items: center; gap: 6px; color: var(--color-muted); font-size: 0.85rem; }
.status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--color-muted); flex-shrink: 0; }
.status-dot.on { background: var(--color-ok); }
.status-dot.dot--busy { box-shadow: 0 0 0 1px var(--color-surface), 0 0 0 3px var(--color-warn); }
.status-dot.dot--unavailable { box-shadow: 0 0 0 1px var(--color-surface), 0 0 0 3px var(--color-danger); }
.person-card__manual { margin: 4px 0 0; font-size: 0.85rem; overflow-wrap: anywhere; }
.person-card__facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 6px 14px; margin: 0; }
.person-card__facts dt { color: var(--color-muted); font-size: 0.8125rem; }
.person-card__facts dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
.person-card__interests h3 { margin: 0 0 6px; font-size: 0.9rem; }
.person-card__interestsText { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
/* CLE-77799 (owner 6da1d88e): one action row, clear of the pane divider, with
   same-size icon+label buttons. Message is the primary; Activity log and Remove
   are secondary (ghost); Remove is the shared readable danger style. */
.person-card__actions { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 4px; }
.person-card__act { display: inline-flex; align-items: center; gap: 6px; }
/* the Change password link is an <a>: same size as the buttons, no underline */
a.person-card__act { min-height: var(--tap, 44px); text-decoration: none; }
.person-card__error { margin: 8px 0 0; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 480px) {
  .person-card__facts { grid-template-columns: minmax(0, 1fr); gap: 0; }
  .person-card__facts dd + dt { margin-top: 8px; }
}
</style>
