-- 0070_human_view_prefs.sql — how a person's message panes are laid out
-- (topic c6994436, Settings -> Behaviour). Forward-only. humans is hub-wide and
-- outside row level security, like submit_key (0062).
-- NULL = never picked: the WUI applies today's layout, so nobody's view changes
-- until they choose.
-- message_order     'newest-first' : the newest message at the top (spec 013).
--                   'newest-last'  : messages appended, the newest at the bottom.
-- composer_position 'top'          : the Omnibox in the top bar (> 820 px).
--                   'bottom'       : the Omnibox docked under the middle pane.
ALTER TABLE humans
    ADD COLUMN message_order text NULL
        CONSTRAINT humans_message_order_check
        CHECK (message_order IS NULL OR message_order IN ('newest-first','newest-last')),
    ADD COLUMN composer_position text NULL
        CONSTRAINT humans_composer_position_check
        CHECK (composer_position IS NULL OR composer_position IN ('top','bottom'));
