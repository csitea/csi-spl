<!-- Settings → Behaviour (specs/023 §3.7, §3.8): "Text fields" decides what
     Enter does in every multi-line field (SPL-976); "Left panel order" is the
     order of the left-rail icons (SPL-979); "Channel order" is the order of
     this workspace's channels (DM 7fa9656f, SPL-1034); "Message order" and "Omnibox
     position" lay out the message panes (topic c6994436). "Link previews" is the
     person's own switch for the cards under internal links (topic e1f8f797).
     "Count my reading time" is the member's hours switch (spec 107 1.2). -->
<template>
  <SettingsSection id="settings-behaviour" :title="t('settings.behaviour')" data-test="settings-behaviour">
    <SubmitKeySetting />
    <RailOrderSetting />
    <ChannelOrderSetting />
    <ViewPrefsSetting />
    <IssuesSortSetting />
    <KeyboardShortcutsSetting />
    <LinkPreviewsSetting />
    <HoursReadingSetting />
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import SubmitKeySetting from '~/components/SubmitKeySetting.vue'
import RailOrderSetting from '~/components/RailOrderSetting.vue'
import ChannelOrderSetting from '~/components/ChannelOrderSetting.vue'
import ViewPrefsSetting from '~/components/ViewPrefsSetting.vue'
import IssuesSortSetting from '~/components/IssuesSortSetting.vue'
import KeyboardShortcutsSetting from '~/components/KeyboardShortcutsSetting.vue'
import LinkPreviewsSetting from '~/components/LinkPreviewsSetting.vue'
import HoursReadingSetting from '~/components/HoursReadingSetting.vue'

const { t } = useI18n({ useScope: 'global' })
</script>
