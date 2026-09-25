<!-- One settings card (specs/023 §3.4): the box every settings section
     renders its content in, with its heading. -->
<template>
  <section class="settings__card" :aria-labelledby="id + '-h'">
    <h3 :id="id + '-h'">{{ title }}</h3>
    <slot />
  </section>
</template>

<script setup lang="ts">
defineProps<{ id: string, title: string }>()
</script>

<style scoped>
.settings__card {
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md, 12px);
  background: var(--color-bg-2);
  padding: 14px 16px;
  min-width: 0;
  max-width: 720px;
}
.settings__card h3 { margin: 0 0 10px; font-size: 0.9375rem; }
</style>
