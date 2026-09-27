<!-- Owner 2026-09-27 (topic 38ba1dae): the top-bar logo is small; a click
     opens it at its true size in the centre of the screen, with the slogan
     "spool-hub - where humans and ai meet". Loaded lazily (LazyLogoDialog):
     the 1920 px picture is fetched only when the dialog opens. -->
<template>
  <UiDialog :open="open" title="spool-hub" size="xl" @update:open="emit('update:open', $event)">
    <figure class="logo-dialog" data-testid="logo-dialog">
      <img
        class="logo-dialog__img"
        src="/spool-hub-emblem.webp"
        width="1920"
        height="1047"
        :alt="t('logo.slogan')"
        decoding="async"
        data-testid="logo-dialog-img"
      >
      <figcaption class="logo-dialog__slogan" data-testid="logo-dialog-slogan">
        <strong>spool-hub</strong> - {{ t('logo.slogan') }}
      </figcaption>
    </figure>
  </UiDialog>
</template>

<script setup lang="ts">
defineProps<{ open: boolean }>()
const emit = defineEmits<{ 'update:open': [boolean] }>()
const { t } = useI18n()
</script>

<style scoped>
.logo-dialog {
  margin: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 12px;
}
.logo-dialog__img {
  display: block;
  max-width: 100%;
  height: auto;
  border-radius: var(--radius-md);
}
.logo-dialog__slogan {
  font-size: 1.25rem;
  text-align: center;
  color: var(--color-fg);
}
</style>
