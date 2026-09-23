<template>
  <div class="login">
    <!-- spec 021: the donor puts the language switcher top-right in its
         header; the sign-in / checkout frame has no header, so it sits in
         the same corner here. -->
    <div class="login-corner" data-test="login-corner">
      <LanguageSwitcher />
    </div>
    <slot />
  </div>
</template>

<script setup lang="ts">
import LanguageSwitcher from '@/components/LanguageSwitcher.vue'
</script>

<style scoped>
.login {
  position: relative;
  /* Equal insets keep the card on the viewport centre. The top inset is
     also the room the corner control needs so the card never slides under it. */
  padding-top: 64px;
  padding-bottom: 64px;
}
.login-corner {
  position: absolute;
  top: 12px;
  inset-inline-end: 12px;
  max-width: calc(100% - 24px);
  min-width: 0;
  z-index: var(--z-sticky, 10);
}
</style>
