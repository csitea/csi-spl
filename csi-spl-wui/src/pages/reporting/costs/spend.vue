<!-- SPL-5312 (spec 143 costs-redesign.md 3.9; owner HUM-10, t1 41a74806:
     "there should be only the following labels - Total, Persons, Cloud,
     Tokens"): the page before the four labels. This route stays so an old
     link still matches; it redirects to /reporting/costs/total, the query kept
     (LegacyMonitoringRedirect, utils/reporting-costs.mjs COSTS_REDIRECTS). -->
<template>
  <LegacyMonitoringRedirect />
</template>
