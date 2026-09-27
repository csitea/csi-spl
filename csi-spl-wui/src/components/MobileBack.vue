<!-- SPL-989: the phone's Back chevron (top-left of levels 2 and 3). Renders
     nothing above 820 px, so the desktop DOM is unchanged. One level down per
     tap, the same step as a swipe right or browser Back (useMobileStack.pop).
     Any page header may mount it; never write another back button. -->
<template>
  <button
    v-if="stack.isMobile.value && stack.level.value > 1"
    type="button"
    class="icon-btn mobile-back"
    data-testid="mobile-back"
    :aria-label="t('mobile.back')"
    :title="t('mobile.back')"
    @click.stop="stack.pop()"
  >
    <UiIcon name="chevron-left" :size="22" class="mobile-back__glyph" />
  </button>
</template>

<script setup lang="ts">
import { useMobileStack } from '~/composables/useMobileStack'

const stack = useMobileStack()
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.mobile-back { display: inline-grid; place-items: center; }
:global([dir="rtl"]) .mobile-back__glyph { transform: scaleX(-1); }
</style>
