<template>
  <!-- SPL-1787 (owner HUM-10, t1 03fc4a65): "Powered by Csitea", the
       Csitea a link to its site; the pattern of csi-rel's AppFooter. Shown
       in the version pop-ups (ChannelSidebar, MobileStatusStrip) and at the
       foot of the sign-in page. -->
  <i18n-t keypath="footer.powered_by" tag="span" scope="global" class="powered-by" data-test="powered-by">
    <template #link>
      <a :href="CSITEA_URL" data-test="footer-csitea-link" target="_blank" rel="noopener noreferrer">Csitea</a>
    </template>
  </i18n-t>
</template>

<script setup lang="ts">
const CSITEA_URL = 'https://csitea.net'
</script>

<style scoped>
.powered-by a { color: var(--color-accent); }
</style>
