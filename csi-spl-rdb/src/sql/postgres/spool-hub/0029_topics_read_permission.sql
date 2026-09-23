-- 0029_topics_read_permission.sql — the read permission is topics.read.
-- Forward-only. 0021 seeded threads.read; that file is already applied, so
-- the rename is a new migration. The hub asks for topics.read.

INSERT INTO rbac_permissions (permission_id, description)
VALUES ('topics.read', 'read roster, channels and topics; open the WUI socket');

UPDATE rbac_role_permissions
   SET permission_id = 'topics.read'
 WHERE permission_id = 'threads.read';

DELETE FROM rbac_permissions WHERE permission_id = 'threads.read';
