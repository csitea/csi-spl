<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): a radar: rings ping out from the centre and fade.
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <circle cx="8" cy="8" r="1.6" fill="currentColor" />
    <g fill="none" stroke="currentColor" stroke-width="1.2">
      <circle class="await-radar__ring" cx="8" cy="8" r="6.5" />
      <circle class="await-radar__ring await-radar__ring--2" cx="8" cy="8" r="6.5" />
    </g>
  </svg>
</template>

<style scoped>
.await-radar__ring { opacity: 0.35; }
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-radar__ring {
    animation: await-radar 1.8s ease-out infinite;
    transform-box: view-box;
    transform-origin: 8px 8px;
  }
  .await-reply--spin .await-radar__ring--2 { animation-delay: 0.9s; }
}
@keyframes await-radar {
  0% { transform: scale(0.2); opacity: 1; }
  100% { transform: scale(1); opacity: 0; }
}
</style>
