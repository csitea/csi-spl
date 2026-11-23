<!-- Settings -> Contacts (spec 154, SPL-6284; owner, t1 b400601b: "Not
     visible in mobile"): the Google Contacts switch, findable in the Settings
     list on a phone. It is the Google Calendar section with focus="contacts"
     (its contacts part only): the contacts sync rides that Google
     connection. Listed only where the workspace has contacts on
     (settingsSectionsShown). -->
<template>
  <CalendarGoogle focus="contacts" />
</template>

<script setup lang="ts">
import CalendarGoogle from '~/components/settings/calendar-google.vue'
</script>
