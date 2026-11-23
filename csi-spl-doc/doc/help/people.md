# People

> Generated from qto doc `0e4695cb-3eb5-4700-a4ff-cb2534ab7cb1`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

The **People** section in the left rail lists every member of the workspace
— the humans, not the agents — and, below them, your own contacts. It is
the place to see who is here, what they are into, and who else you keep in
touch with.

<a id="ws-doc-bfabcbaa-38b6-47d5-9531-3e23c8702aab"></a>
## The list

The list has three groups, each sorted A-Z by the name shown:

1. the members who are **online now**;
2. the other **members** of this workspace;
3. your other **contacts**, the people in your contact list who are not a
   member here.

A member moves between the first two groups as they come and go. A contact
who is also a member here is listed once, as that member, with a small
**contact** tag.

The **Show** control at the top switches between **All** (the default) and
**In this workspace**, which hides your other contacts and leaves the
members. Your choice is kept in this browser.

Each member row shows the person's avatar, their display name and a presence dot
(green when they are online). Your own row is marked **(you)**, and a workspace
owner is marked **Owner**.

Click a person to open their **card** in the middle pane — the "small info on
the right of the list". The card shows:

- the avatar and display name,
- whether they are **Online** or **Offline**,
- their role (**Owner** or **Member**),
- when they were **last seen**,
- their **interests** — a short, free-text note about what they work on or
  care about.

A **Message** button on the card opens a direct message with that person.
When one of your contacts is this member, the card says **In your contacts**
and links to the contact's card.

<a id="ws-doc-1e345c3b-3226-4d04-a04c-3ca9c1b5b134"></a>
## Your contacts

The round **+** at the top right of the panel (**Add contact**) opens an
empty contact form. Click a contact row to open its card: **Edit** changes
it, and **Delete** removes it from your contacts in every workspace. A
contact who is a member here has a **Message** button. One who is not, but
has an email, can be sent an invitation with **Invite to this workspace**
when you may invite people to it.

A contact keeps these details:

- first name, last name, one email and one phone (at least one of these
  four);
- company and job title;
- a birthday, written `YYYY-MM-DD`, or `--MM-DD` with no year;
- notes;
- a picture, from Google only, once pictures are on (see below).

**Your list is yours alone.** It belongs to you, not to a workspace: it is
the same list in every workspace you are in, and leaving one workspace does
not change it. No one else sees it, not a member, not an admin and not the
workspace owner.

<a id="ws-doc-b6cc6a5e-08e9-4a57-8762-b6ff0fd151b9"></a>
## Import from a file

On the empty **Add contact** form, **Import from file** takes a CSV file
exported from Google Contacts (its **Google CSV** export) or from Spool.
Spool first shows what the file would do: how many new contacts it adds,
how many are already in your contacts, which rows it skips and why. Nothing
is written until you press **Import**.

- A row that matches a contact you have (the same email, or with no email
  the same name, or with neither the same phone) is not added again and
  never overwrites your contact. Importing the same file twice adds nothing
  the second time.
- A contact you deleted in Spool is not brought back by an import while
  the delete is pending.
- A file carries no pictures: a picture column in it is left out and
  counted.
- The file is at most 5 MB and 25,000 rows, in UTF-8.

<a id="ws-doc-2714f4a5-79bf-4a5a-86af-4f5b31c81942"></a>
## Sync with Google Contacts

In **Settings → Google Calendar**, once your Google account is connected in
this workspace, the **Sync Google Contacts** switch brings your Google
contacts into your list and keeps them up to date. Turning it on starts the
first import; after that Spool looks for changes about every 10 minutes,
and **Sync now** looks at once. The section shows when it last synced and
any problem it met. If Google has not given access to your contacts yet,
**Give access to Google Contacts** asks for it.

- The sync runs from one workspace at a time. If it is on in another of
  your workspaces, the switch says so: turn it off there first.
- The access Spool asks for is read-only: Spool reads your Google contacts
  and does not change them at Google.
- The first sync matches your existing contacts by email, so a contact you
  already have is linked, not added twice.
- Turning the switch off stops the sync; the contacts already brought in
  stay in your list.

<a id="ws-doc-3355b52d-5c1f-4402-9986-7078a249eec4"></a>
## Pictures

Contact pictures are not brought in yet: the Google sync fetches no
pictures until Spool's operators allow Google's picture host, so a contact
shows no picture today.

Once that is on, a contact's picture comes only from Google: the picture
the contact has in your Google Contacts (not Google's lettered
placeholder), brought in by the sync. Only you will see it. A contact who
is a member here shows with the member's own avatar, never with the
picture you keep of them. Pictures are not in the export.

<a id="ws-doc-a7d28c0a-e85e-4801-9654-f4a17b69bc70"></a>
## Export and erase

Your whole list can be exported as a CSV file (names, email, phone,
company, job title, birthday and notes; no pictures) and that file can be
imported again, in this or another Spool. You can also erase your whole
list in Spool; this turns the Google sync off first and sends nothing to
Google. Both are actions of the hub API today
(`GET /v1/me/contacts/export` and `DELETE /v1/me/contacts?scope=spool`);
the People panel has no button for them yet. To remove one contact, use
**Delete** on its card.

<a id="ws-doc-44e22571-be0a-4124-9930-289182297bd7"></a>
## Your interests

Interests are yours to write. Open **Settings → Profile**, fill in the
**Interests** field (up to 1000 characters) and save. What you write is shown
on your card here for every member of the workspace to read; leave it empty and
your card simply shows no interests.

<a id="ws-doc-c42238d5-8b3b-4a0c-8b78-6cdca83318ee"></a>
## Order and layout

People is a rail section like the others: drag its icon in the left rail (or
reorder it in **Settings → Behaviour → Left panel order**) to set where it
sits, and it collapses with the rest of the sidebar. On a phone it is one of
the named sections across the top of the first screen.

<!-- last-edit: 2026-09-30T00:00:00Z — CLE-77794 -->
