<!-- SPL-1991: Monitoring -> Boxes (v1). A thin list over the roster the
     sidebar's Boxes section reads (utils/box-rows.mjs, machines only), each
     row opening today's card at /boxes/<id>. The BoxCard extraction is the
     next lane's. -->
<template>
  <div class="monitoring-list" data-test="monitoring-boxes">
    <p v-if="rows.length === 0" class="muted monitoring-empty" data-test="monitoring-boxes-empty">{{ t('boxes.none') }}</p>
    <div v-for="b in rows" :key="b.id" class="nav-row">
      <NuxtLink
        class="nav-item"
        :data-key="b.id"
        :data-online="b.online ? '1' : '0'"
        :to="localePath('/boxes/' + encodeURIComponent(b.id))"
      >
        <UiIcon name="server" :size="20" />
        <span class="dot" :class="{ on: b.online }" />
        <span class="label">{{ b.tag }}</span>
      </NuxtLink>
      <LazyBoxSeatCounts :box="b" />
    </div>
  </div>
</template>

<script setup lang="ts">
import { useRosterStore } from '~/stores/roster'
import { boxRows } from '~/utils/box-rows.mjs'

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const roster = useRosterStore()
const rows = computed(() => boxRows(roster.people, roster.boxes))
</script>

