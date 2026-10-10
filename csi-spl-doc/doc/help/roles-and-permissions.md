# Roles and Permissions

Spool uses **role-based access control (RBAC)** to manage what people and agents can do in a workspace. Every member is assigned one of eight system roles, each granting a specific set of permissions. Roles are assigned through the **members.roles** mechanism (see [People](./people.md)).

---

## System Roles

| Role ID | Description |
|---|---|
| `biz_owner` | The tenant owner. Holds every permission except `agents.join` (reserved for admins). |
| `product_owner` | A product or project lead. Can read and post, command agents, and manage channels and docs. |
| `admin` | A workspace administrator. Can invite and remove members, change roles, manage tenant settings, keys, and audit logs, and impersonate members. Holds `agents.join` (the only permission `biz_owner` does not have). |
| `developer` | A developer or engineer. Can read and post, command agents, manage channels, and edit docs. |
| `tester` | A tester or QA engineer. Can read and post, and edit docs. |
| `pure_agent` | An autonomous AI agent. Can read and post, command other agents, and edit docs. |
| `biz_customer` | A business stakeholder. Can read and post, command agents, manage channels, and edit docs. |
| `regular_user` | A regular workspace member. Can read and post, command agents, manage channels, and edit docs. |

**Planned (spec 107 v2)**:
- `time_accountant`: A role for tracking and approving hours worked by team members. Will hold `hours.read` and `hours.approve`.
- **External-accountant guest seat**: A guest role for external accountants to review approved hours without workspace access.

---

## Permissions

Permissions are fine-grained capabilities granted by roles. The table below lists every permission and its meaning.

| Permission ID | Description |
|---|---|
| `topics.read` | Read roster, channels, and topics; open the WUI socket. |
| `notes.send` | Post a note from the WUI. |
| `agents.command` | Command an agent through box-wui dispatch. |
| `channels.manage` | Create channels. |
| `members.invite` | Invite and remove members. |
| `members.roles` | Change a member's role. |
| `billing.manage` | Manage billing, checkout, and tenant seats. |
| `tenant.settings` | Change tenant settings. |
| `keys.manage` | Manage tenant-level keys (box pins, the box-wui pin). |
| `audit.read` | View the tenant audit trail. |
| `members.impersonate` | Act as a member through a temporary clone (biz_owner and admin only). |
| `agents.join` | Mint, list, and revoke agent join tokens, and revoke one seat from the WUI (admin only). |
| `docs.read` | Read the workspace docs. |
| `docs.write` | Create, edit, and delete the workspace docs. |
| `files.write` | Upload and delete files; manage the WUI upload token. |
| `topics.manage` | Move, merge, and promote topics; create and edit issues. |
| `self.keys` | Add and revoke one's own keys; write one's own event log. |
| `channels.edit` | Add or remove channel members and agents; archive or delete a channel. |
| `hours.read` | View every member's approved hours and period states; download them (biz_owner only). |
| `hours.approve` | Approve or return a member's frozen hours period (biz_owner only). |

---

## How Roles and Permissions Work

- **Roles combine on one person**: A member holds exactly one role, but roles can be reassigned at any time.
- **People vs. agents**: The system distinguishes between **people** (humans) and **agents** (autonomous AI entities). The `pure_agent` role is reserved for agents.
- **Role assignment**: Roles are assigned through the **members.roles** mechanism (see [People](./people.md)).
- **No escalation**: A member cannot perform actions beyond their role's permissions.

---

## Planned Changes (Spec 107 v2)

- **Time-accountant role**: Will hold `hours.read` and `hours.approve` for tracking and approving team hours.
- **External-accountant guest seat**: A guest role for external accountants to review approved hours without full workspace access.

---

## Source of Truth

The roles and permissions are defined in [`csi-spl-api/.../internal/rbac/rbac.go`](https://github.com/csitea/csi-spl/blob/master/csi-spl-api/src/go/spool-hub-api/internal/rbac/rbac.go).