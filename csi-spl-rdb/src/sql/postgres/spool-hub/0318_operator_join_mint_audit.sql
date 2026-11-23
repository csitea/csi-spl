-- 0318_operator_join_mint_audit.sql - the operator join-token mint is audited
-- (spec 181 row B7, SPL-6329; spec 181 4.2, spec 122 4 point 5). Forward-only,
-- idempotent (DROP CONSTRAINT IF EXISTS, then ADD).
--
-- The spool-hub admin mints, for a private workspace, a one-use join token
-- bound to its private VM's box id (POST /v1/operator/workspaces/{id}/join-tokens,
-- store MintOperatorJoinToken). The token row goes to agent_join_tokens (rdb
-- 0119, unchanged); its audit row goes to operator_audit with the new action
-- mint_join_token, in the same transaction. The CHECK of rdb 0212 is replaced
-- by one wider by that action; no table, column or policy changes.
--
-- Live-data safety: every stored row passes the wider CHECK; no row is
-- written or deleted.
-- DEPLOY ORDER: apply BEFORE the hub that writes the new action (wf 20 does).

SET LOCAL lock_timeout = '5s';

ALTER TABLE operator_audit DROP CONSTRAINT IF EXISTS operator_audit_action_check;
ALTER TABLE operator_audit ADD CONSTRAINT operator_audit_action_check
    CHECK (action IN ('list', 'read', 'create', 'update', 'suspend', 'resume', 'archive',
                      'set_agent_caps', 'delete_agent_cap', 'mint_join_token'));
