<!-- A page's one action on a phone, at the bottom centre just above the dock
     (and above the keyboard when it is up): the Event log's Clear log
     (SPL-2093, owner t1 04d9c246) and Monitoring -> Lanes' Refresh, which the
     owner put "in the same place where the clear lock button is" (SPL-5276,
     t1 e1e97af9, msg 2dedcc73). Under the page sheets (z 38/39) and the dock.
     The page keeps a spacer of --tap + 16px under its list so the last row
     scrolls clear of it. Attributes and listeners fall through to the button. -->
<template>
  <button type="button" class="btn phone-dock-btn"><slot /></button>
</template>

<style scoped>
.phone-dock-btn {
  position: fixed;
  inset-inline-start: 50%;
  bottom: calc(var(--composer-dock-h, 0px) + var(--kb-inset, 0px) + 8px);
  z-index: 30;
  transform: translateX(-50%);
  min-height: var(--tap, 44px);
  box-shadow: 0 2px 8px rgb(0 0 0 / .3);
}
:global([dir="rtl"]) .phone-dock-btn { transform: translateX(50%); }
</style>
