<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): three dots that bounce in turn, like someone typing.
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <g fill="currentColor">
      <circle class="await-dots__dot" cx="3.2" cy="9" r="1.7" />
      <circle class="await-dots__dot await-dots__dot--2" cx="8" cy="9" r="1.7" />
      <circle class="await-dots__dot await-dots__dot--3" cx="12.8" cy="9" r="1.7" />
    </g>
  </svg>
</template>

<style scoped>
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-dots__dot { animation: await-dots 1.1s ease-in-out infinite; }
  .await-reply--spin .await-dots__dot--2 { animation-delay: 0.15s; }
  .await-reply--spin .await-dots__dot--3 { animation-delay: 0.3s; }
}
@keyframes await-dots {
  0%, 60%, 100% { transform: translateY(0); opacity: 0.5; }
  30% { transform: translateY(-3.5px); opacity: 1; }
}
</style>
