<!-- CLE-77799 (owner 2026-09-30, topic 1fc29f99: "we should have a boxes section
     as well ... people use boxes and agents use boxes"): a box's card. Its id
     and machine tag, whether it is online, when it last checked in, and who is
     seated on it — BOTH the people (their browser / app sessions) AND the agents
     — each linked to their People / Agents card. Read from /v1/view/roster.
     Machines only (owner, t1 topic b3bf3d13): a link to the browser pseudo-box
     (/boxes/box-wui) is not a machine, so it goes back to the Boxes list. -->
<template>
  <div class="feed-col" data-test="box-page">
    <header class="feed-header">
      <MobileBack />
      <h2 class="box-head">
        <UiIcon name="server" :size="22" />
        <span>{{ box.tag }}</span>
      </h2>
    </header>
    <div class="feed-body">
      <div class="box-card" data-test="box-card">
        <div class="box-card__hero">
          <span class="box-card__glyph" aria-hidden="true"><UiIcon name="server" :size="34" /></span>
          <div class="box-card__heroText">
            <p class="box-card__name">{{ box.tag }}</p>
            <p class="box-card__kind" data-test="box-kind">{{ box.browser ? t('boxes.browser') : t('boxes.machine') }}</p>
            <p class="box-card__status" data-test="box-status">
              <span class="status-dot" :class="{ on: box.online }" aria-hidden="true" />
              {{ box.online ? t('people.online') : t('people.offline') }}
            </p>
          </div>
        </div>
        <dl class="box-card__facts">
          <dt>{{ t('boxes.id') }}</dt>
          <dd data-test="box-id"><code>{{ boxId }}</code></dd>
          <dt>{{ t('people.last_seen') }}</dt>
          <dd data-test="box-last-hello">{{ lastHello }}</dd>
          <dt>{{ t('boxes.users') }}</dt>
          <dd data-test="box-user-total">{{ box.userCount }}</dd>
        </dl>

        <!-- the people seated on this box (their WUI / app sessions) -->
        <section class="box-card__seats">
          <h3>{{ t('sidebar.people') }} <span class="muted box-card__n">{{ box.people.length }}</span></h3>
          <p v-if="box.people.length === 0" class="muted" data-test="box-no-people">{{ t('boxes.no_people') }}</p>
          <NuxtLink
            v-for="p in box.people"
            :key="p.label"
            class="box-seat"
            data-test="box-person"
            :data-key="p.id"
            :to="localePath('/people/' + encodeURIComponent(p.id))"
          >
            <SpoolAvatar :id="p.id" :box="p.box" :size="22" />
            <span class="status-dot" :class="{ on: p.online }" aria-hidden="true" />
            <HumanName class="box-seat__label" :id="p.id" :box="p.box" />
          </NuxtLink>
        </section>

        <!-- the agents seated on this box -->
        <section class="box-card__seats">
          <h3>{{ t('sidebar.agents') }} <span class="muted box-card__n">{{ box.agents.length }}</span></h3>
          <p v-if="box.agents.length === 0" class="muted" data-test="box-no-agents">{{ t('boxes.no_agents') }}</p>
          <NuxtLink
            v-for="a in box.agents"
            :key="a.label"
            class="box-seat"
            data-test="box-agent"
            :data-key="a.label"
            :to="localePath('/agents/' + encodeURIComponent(a.label))"
          >
            <UiIcon name="bot" :size="20" />
            <span class="status-dot" :class="{ on: a.online }" aria-hidden="true" />
            <span class="box-seat__label">{{ a.id }}</span>
            <span class="muted box-seat__kind">{{ t(agentKindLabelKey(a.id)) }}</span>
          </NuxtLink>
        </section>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useRosterStore } from '~/stores/roster'
import { agentKindLabelKey } from '~/utils/agent-kind.mjs'
import { boxByID, isBrowserBox } from '~/utils/box-rows.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'

const route = useRoute()
const roster = useRosterStore()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })

const boxId = computed(() => decodeURIComponent(String(route.params.id || '')))
const box = computed(() => boxByID(boxId.value, roster.people, roster.boxes))
const lastHello = computed(() => (box.value.lastHello ? isoDateTime(box.value.lastHello) : t('people.never_seen')))

/* machines only: the browser box has no card, its old link lands on the list */
if (isBrowserBox(boxId.value)) void navigateTo(localePath('/boxes'), { replace: true })

/* the roster is already loaded for the DM list; refresh once so a deep link
   straight to this card (no sidebar visited yet) still has the seats. */
onMounted(() => { if (!roster.boxes[boxId.value] && box.value.userCount === 0) void roster.refresh() })
</script>

<style scoped>
.box-head { display: flex; align-items: center; gap: 8px; min-width: 0; }
.box-card { padding: 16px; max-width: 640px; display: flex; flex-direction: column; gap: 18px; min-width: 0; }
.box-card__hero { display: flex; align-items: center; gap: 14px; min-width: 0; }
.box-card__glyph {
  display: inline-flex; align-items: center; justify-content: center;
  width: 56px; height: 56px; border-radius: var(--radius-md); flex-shrink: 0;
  background: color-mix(in srgb, var(--color-accent) 14%, var(--color-surface));
  color: var(--color-accent);
}
.box-card__heroText { min-width: 0; }
.box-card__name { margin: 0; font-size: 1.1rem; font-weight: 700; overflow-wrap: anywhere; }
.box-card__kind { margin: 2px 0 0; font-weight: 600; color: var(--color-accent); }
.box-card__status { margin: 4px 0 0; display: flex; align-items: center; gap: 6px; color: var(--color-muted); font-size: 0.85rem; }
.status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--color-muted); flex-shrink: 0; }
.status-dot.on { background: var(--color-ok); }
.box-card__facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 6px 14px; margin: 0; }
.box-card__facts dt { color: var(--color-muted); font-size: 0.8125rem; }
.box-card__facts dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
.box-card__seats h3 { margin: 0 0 6px; font-size: 0.9rem; display: flex; align-items: center; gap: 6px; }
.box-card__n { font-weight: 400; font-size: 0.8rem; }
.box-seat {
  display: flex; align-items: center; gap: 8px; min-width: 0;
  padding: 5px 6px; border-radius: var(--radius-sm); color: inherit; text-decoration: none;
}
.box-seat:hover { background: var(--color-surface-hover); }
.box-seat :deep(.spool-avatar) { border-radius: 50%; flex-shrink: 0; }
.box-seat__label { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.box-seat__kind { margin-inline-start: auto; font-size: 0.75rem; flex-shrink: 0; }
@media (max-width: 480px) {
  .box-card__facts { grid-template-columns: minmax(0, 1fr); gap: 0; }
  .box-card__facts dd + dt { margin-top: 8px; }
}
</style>
