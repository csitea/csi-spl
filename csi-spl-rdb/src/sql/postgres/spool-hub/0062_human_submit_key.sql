-- 0062_human_submit_key.sql — how Enter behaves in a person's text fields
-- (SPL-976, spec 023 3.7). Forward-only. humans is hub-wide and outside row
-- level security, like preferred_theme (0057).
-- NULL = never picked: the WUI applies its default (spec 023 3.7).
-- 'enter'      : Enter sends / saves, Shift+Enter adds a line.
-- 'ctrl-enter' : Enter adds a line, Ctrl+Enter (Cmd+Enter on macOS) sends / saves.
ALTER TABLE humans
    ADD COLUMN submit_key text NULL
        CONSTRAINT humans_submit_key_check
        CHECK (submit_key IS NULL OR submit_key IN ('enter','ctrl-enter'));
