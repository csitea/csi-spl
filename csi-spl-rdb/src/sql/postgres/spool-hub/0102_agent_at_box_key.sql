-- 0102_agent_at_box_key.sql — the hub keys agents on (id, box) (spec 061
-- section 3.3.1, FR-015, lane L1b). Forward-only.
--
-- Owner, 2026-10-02 ~06:50Z: every machine numbers c-004..c-999 on its own,
-- so c-004@box-desk and c-004@<sat box> are two agents. Before any machine
-- hands out a per-box number, every place that names an agent carries its
-- box. The box is a COLUMN of the key where the table has one, and the
-- <ID>@<box> form where the field is one text value:
--
--   roster      (tenant_id, box_id, agent_id) - already keyed on the box (0001)
--   messages    from_box / to_box columns      - already (0001)
--   fleet_leases holder = <ID>@<box>           - already required (0095)
--   fleet_lanes agent_box column               - the KEY gains it (below)
--   fleet_asks  from_agent / acked_by / closed_by: <ID> or <ID>@<box> (0097);
--               bare rows are back-filled with the box that wrote them, and
--               the hub writes the box in from now on (below)
--   issues      assignee: <ID>@<box> accepted next to a bare id (below)

-- fleet_lanes: one row per agent AT ITS BOX. agent_box is NOT NULL since
-- 0096, so every existing row already carries its box: no back-fill.
ALTER TABLE fleet_lanes DROP CONSTRAINT fleet_lanes_pkey;
ALTER TABLE fleet_lanes ADD CONSTRAINT fleet_lanes_pkey PRIMARY KEY (tenant_id, fleet, agent_id, agent_box);

-- fleet_asks: a bare sender / acker / closer gets the box the hub recorded
-- for the row's last write (writer_box, from the authenticated hello). For
-- from_agent of a never-updated ask and for closed_by that is exactly the
-- writer; for acked_by of a closed ask it is the closer's box, the best the
-- hub knows. Legacy ids are unique across the fleet, so no row is mis-joined.
UPDATE fleet_asks SET from_agent = from_agent || '@' || writer_box
    WHERE from_agent !~ '@' AND writer_box ~ '^[a-z0-9][a-z0-9-]{0,31}$';
UPDATE fleet_asks SET acked_by = acked_by || '@' || writer_box
    WHERE acked_by <> '' AND acked_by !~ '@' AND writer_box ~ '^[a-z0-9][a-z0-9-]{0,31}$';
UPDATE fleet_asks SET closed_by = closed_by || '@' || writer_box
    WHERE closed_by <> '' AND closed_by !~ '@' AND writer_box ~ '^[a-z0-9][a-z0-9-]{0,31}$';

-- issues: an assignee may name the box. Existing bare assignees stay: they
-- are legacy ids, unique across the fleet, and the hub resolves a bare id to
-- its single box.
ALTER TABLE issues DROP CONSTRAINT issues_assignee_check;
ALTER TABLE issues ADD CONSTRAINT issues_assignee_check
    CHECK (assignee = '' OR assignee ~ '^([acgq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]+)(@[a-z0-9][a-z0-9-]{0,31})?$');
