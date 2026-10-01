<!-- CLE-77851: the mark on a left-pane row the reader muted in this browser.
     A muted row used to be only faded (opacity 0.55), which reads as
     "inactive" or "not a member" (csitea #csi-fina, HUM-24: a member saw her
     own channel pale and nobody could say why). The row now keeps its normal
     look and shows this muted bell; a click unmutes, as the row menu's Unmute
     does. It sits on the row, outside the link, just before the row menu. -->
<template>
  <button
    type="button"
    class="icon-btn row-muted"
    data-testid="row-muted"
    :aria-label="label"
    :title="label"
    @click.stop.prevent="emit('unmute')"
  >
    <UiIcon name="bell-off" :size="16" />
  </button>
</template>

<script setup lang="ts">
const props = defineProps<{ name: string }>()
const emit = defineEmits<{ unmute: [] }>()
const { t } = useI18n({ useScope: 'global' })
const label = computed(() => t('sidebar.row_muted', { name: props.name }))
</script>

<style scoped>
.row-muted {
  position: absolute;
  inset-inline-end: 40px;
  top: 50%;
  transform: translateY(-50%);
  min-width: 28px;
  min-height: 28px;
  width: 28px;
  height: 28px;
  color: var(--color-muted);
  z-index: 1;
}
</style>
