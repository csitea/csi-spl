<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): two gears turning against each other.
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <g fill="none" stroke="currentColor">
      <g class="await-gears__big">
        <circle cx="6" cy="6" r="3.6" stroke-width="2" stroke-dasharray="1.4 1.43" />
        <circle cx="6" cy="6" r="2.4" stroke-width="1.2" />
      </g>
      <g class="await-gears__small">
        <circle cx="11.6" cy="11.4" r="2.5" stroke-width="1.8" stroke-dasharray="1.1 1.12" />
        <circle cx="11.6" cy="11.4" r="1.5" stroke-width="1" />
      </g>
    </g>
  </svg>
</template>

<style scoped>
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-gears__big {
    animation: await-gears 3s linear infinite;
    transform-box: view-box;
    transform-origin: 6px 6px;
  }
  .await-reply--spin .await-gears__small {
    animation: await-gears 2.1s linear infinite reverse;
    transform-box: view-box;
    transform-origin: 11.6px 11.4px;
  }
}
@keyframes await-gears {
  to { transform: rotate(360deg); }
}
</style>
