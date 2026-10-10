<!-- HUM-10 (t1 58857a17): a boxes rail row's "N people · M agents", each count
     a link to its own list on the box's card (/boxes/<id>#box-people or
     #box-agents). It sits beside the row's link, never inside it (a link
     holds no link). Its own lazy chunk: the home bundle carries none of it. -->
<template>
  <span class="muted box-row__counts" data-testid="box-seat-counts" :data-box="box.id">
    <NuxtLink
      class="box-row__count"
      data-testid="box-people-count"
      :data-count="box.people.length"
      :to="href + '#box-people'"
    >{{ t('boxes.people_n', box.people.length) }}</NuxtLink>
    <span aria-hidden="true">·</span>
    <NuxtLink
      class="box-row__count"
      data-testid="box-agents-count"
      :data-count="box.agents.length"
      :to="href + '#box-agents'"
    >{{ t('boxes.agents_n', box.agents.length) }}</NuxtLink>
  </span>
</template>

<script setup lang="ts">
const props = defineProps<{ box: { id: string, people: unknown[], agents: unknown[] } }>()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const href = computed(() => localePath('/boxes/' + encodeURIComponent(props.box.id)))
</script>

<style scoped>
/* on a second line under the box's name; the row makes room below the name */
.box-row__counts {
  position: absolute; inset-inline-start: 58px; inset-inline-end: 8px; bottom: 4px;
  display: flex; align-items: center; gap: 4px; font-size: 0.6875rem; line-height: 1.3;
  white-space: nowrap; overflow: hidden;
}
.box-row__count { color: inherit; text-decoration: none; }
.box-row__count:hover, .box-row__count:focus-visible { color: var(--color-accent); text-decoration: underline; }
</style>
