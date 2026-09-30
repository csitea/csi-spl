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
              <span class="status-dot" :class="{ on: online }" aria-hidden="true" />
              {{ online ? t('people.online') : t('people.offline') }}
            </p>
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
        <div v-if="!isSelf" class="person-card__actions">
          <button type="button" class="btn" data-test="person-message" @click="message">{{ t('people.message') }}</button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useRosterStore } from '~/stores/roster'
import { isoDateTime } from '~/utils/date-iso.mjs'

const route = useRoute()
const roster = useRosterStore()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })

const humanId = computed(() => decodeURIComponent(String(route.params.id || '')))
const detail = computed(() => roster.humansDetail[humanId.value] || { owner: false, interests: '', last_seen: '' })
const isOwner = computed(() => detail.value.owner || roster.owners.includes(humanId.value))
const interests = computed(() => String(detail.value.interests || '').trim())
const online = computed(() => roster.isOnline(humanId.value, 'box-wui'))
const isSelf = computed(() => roster.self?.id === humanId.value)
const lastSeen = computed(() => (detail.value.last_seen ? isoDateTime(detail.value.last_seen) : t('people.never_seen')))

/* the roster is already loaded for the DM list; refresh once so a deep link
   straight to this card (no sidebar visited yet) still has the detail. */
onMounted(() => { if (!roster.humansDetail[humanId.value]) void roster.refresh() })

function message() {
  void navigateTo(localePath('/dm/' + encodeURIComponent(humanId.value + '@box-wui')))
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
.person-card__facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 6px 14px; margin: 0; }
.person-card__facts dt { color: var(--color-muted); font-size: 0.8125rem; }
.person-card__facts dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
.person-card__interests h3 { margin: 0 0 6px; font-size: 0.9rem; }
.person-card__interestsText { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
.person-card__actions { display: flex; gap: 8px; }
@media (max-width: 480px) {
  .person-card__facts { grid-template-columns: minmax(0, 1fr); gap: 0; }
  .person-card__facts dd + dt { margin-top: 8px; }
}
</style>
