<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): a planet with a moon going round it.
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <ellipse cx="8" cy="8" rx="6.4" ry="6.4" fill="none" stroke="currentColor" stroke-width=".8" opacity=".35" />
    <circle cx="8" cy="8" r="2.6" fill="currentColor" />
    <circle class="await-orbit__moon" cx="8" cy="1.6" r="1.4" fill="currentColor" />
  </svg>
</template>

<style scoped>
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-orbit__moon {
    animation: await-orbit 1.6s linear infinite;
    transform-box: view-box;
    transform-origin: 8px 8px;
  }
}
@keyframes await-orbit {
  to { transform: rotate(360deg); }
}
</style>
