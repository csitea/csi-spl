<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): a wave running along a line.
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <path d="M1 8h14" fill="none" stroke="currentColor" stroke-width=".8" opacity=".3" />
    <path class="await-wave__crest" d="M1 8c1.2-4 2.3-4 3.5 0s2.3 4 3.5 0 2.3-4 3.5 0 2.3 4 3.5 0" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" pathLength="40" stroke-dasharray="10 30" />
  </svg>
</template>

<style scoped>
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-wave__crest { animation: await-wave 1.2s linear infinite; }
}
@keyframes await-wave {
  from { stroke-dashoffset: 10; }
  to { stroke-dashoffset: -30; }
}
</style>
