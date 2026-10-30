<!-- SPL-4382 (spec 143 costs-redesign.md 3.8; owner HUM-10, t1 4f48f878, msg
     baa43948: "the costs section in the reporting will be only the costs
     reporting type of data"): the paid items are entered under Expenses ->
     AI costs. This route stays so an old link still matches; it redirects to
     /expenses/ai, the query kept (LegacyMonitoringRedirect,
     utils/reporting-costs.mjs COSTS_REDIRECTS). -->
<template>
  <LegacyMonitoringRedirect />
</template>
