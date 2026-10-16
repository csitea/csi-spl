<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): a pencil writing a line, which draws itself again and again.
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <path class="await-pencil__line" d="M1 13.6c1.2-2.4 2.4 2.4 3.6 0s2.4 2.4 3.6 0 2.4 2.4 3.6 0" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" pathLength="20" stroke-dasharray="20" />
    <g class="await-pencil__pen" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round">
      <path d="m3.2 11.6 7.2-7.2 2 2-7.2 7.2-2.6.6zM9.2 5.6l2 2" />
    </g>
  </svg>
</template>

<style scoped>
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-pencil__line { animation: await-pencil-line 1.8s linear infinite; }
  .await-reply--spin .await-pencil__pen { animation: await-pencil 1.8s linear infinite; }
}
@keyframes await-pencil-line {
  0% { stroke-dashoffset: 20; }
  80%, 100% { stroke-dashoffset: 0; }
}
@keyframes await-pencil {
  0% { transform: translate(-2px, 0); }
  20% { transform: translate(0, -1px); }
  40% { transform: translate(2px, 0); }
  60% { transform: translate(4px, -1px); }
  80% { transform: translate(6px, 0); }
  100% { transform: translate(-2px, 0); }
}
</style>
