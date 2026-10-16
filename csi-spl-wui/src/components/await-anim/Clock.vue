<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): a clock whose hands race round.
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <circle cx="8" cy="8" r="6.6" fill="none" stroke="currentColor" stroke-width="1.3" />
    <g fill="none" stroke="currentColor" stroke-linecap="round">
      <path class="await-clock__hour" d="M8 8V5" stroke-width="1.5" />
      <path class="await-clock__minute" d="M8 8V2.9" stroke-width="1.1" />
    </g>
    <circle cx="8" cy="8" r=".9" fill="currentColor" />
  </svg>
</template>

<style scoped>
.await-clock__hour,
.await-clock__minute { transform-box: view-box; transform-origin: 8px 8px; }
.await-clock__hour { transform: rotate(120deg); }
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-clock__minute { animation: await-clock 1.2s linear infinite; }
  .await-reply--spin .await-clock__hour { animation: await-clock-hour 14.4s linear infinite; }
}
@keyframes await-clock {
  to { transform: rotate(360deg); }
}
@keyframes await-clock-hour {
  from { transform: rotate(120deg); }
  to { transform: rotate(480deg); }
}
</style>
