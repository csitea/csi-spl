-- 0077_human_close_buttons.sql — which corner a person's close buttons sit in
-- (SPL-1133, spec 023, Settings -> Behaviour). Forward-only. humans is hub-wide
-- and outside row level security, like the other layout choices (0070, 0072).
--
-- Owner, 2026-09-28 (prd t1 topic 9e0379a6): "a User Setting to put the X's
-- for closing the modal dialogs etc. either Windows style, i.e. top right, or
-- Mac style, i.e. top left", then "use the Mac style as the default".
--
-- NULL = never picked: the WUI applies the default, Mac style.
-- close_buttons 'mac'     : every close X in the top left (the default).
--               'windows' : every close X in the top right.
ALTER TABLE humans
    ADD COLUMN IF NOT EXISTS close_buttons text NULL;

ALTER TABLE humans DROP CONSTRAINT IF EXISTS humans_close_buttons_check;
ALTER TABLE humans ADD CONSTRAINT humans_close_buttons_check
    CHECK (close_buttons IS NULL OR close_buttons IN ('mac','windows'));
