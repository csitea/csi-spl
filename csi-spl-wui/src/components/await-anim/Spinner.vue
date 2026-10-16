<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): a ring with a bright arc going round.
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.6" opacity=".25" />
    <path class="await-spinner__arc" d="M8 2a6 6 0 0 1 6 6" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" />
  </svg>
</template>

<style scoped>
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-spinner__arc {
    animation: await-spinner 0.9s linear infinite;
    transform-box: view-box;
    transform-origin: 8px 8px;
  }
}
@keyframes await-spinner {
  to { transform: rotate(360deg); }
}
</style>
