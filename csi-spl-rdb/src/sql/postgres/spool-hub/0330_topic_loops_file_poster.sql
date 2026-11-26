-- 0330_topic_loops_file_poster.sql - the file trigger of a discussion loop
-- split by who posted (spec 182 v0.11 section 8.8 change 9, SPL-6588; owner
-- HUM-10, t1 6e8c1cdb msg d8e02722: "after an agent post with one or more
-- files attached" and "after a human post with one or more files attached").
-- Forward-only, additive, idempotent.
--
-- topic_loops.triggers admits two more keys:
--   post_has_file_agent : an agent post with one or more files fires it;
--   post_has_file_human : a human post with one or more files fires it.
-- post_has_file stays in the list: a loop stored with it keeps firing on
-- either poster as before (store TopicLoopTriggers keeps the key; the WUI
-- form no longer offers it). No row changes.
--
-- Live-data safety: the CHECK only widens, so every stored row passes it;
-- it is re-added NOT VALID, so topic_loops is not scanned under the ACCESS
-- EXCLUSIVE lock, and every new or changed row is checked. lock_timeout
-- bounds the wait for that lock. No personal data, no secret.
SET LOCAL lock_timeout = '5s';

ALTER TABLE topic_loops DROP CONSTRAINT IF EXISTS topic_loops_triggers_check;
ALTER TABLE topic_loops ADD CONSTRAINT topic_loops_triggers_check
    CHECK (triggers <@ ARRAY['after_agent_reply', 'before_agent_reply', 'after_human_reply',
                             'every_hour', 'every_n_minutes',
                             'post_has_keyword', 'post_has_file', 'post_has_file_agent', 'post_has_file_human',
                             'blocker_posted', 'no_reply_after_human', 'issue_status_changed', 'daily_at']
           AND cardinality(triggers) >= 1) NOT VALID;
