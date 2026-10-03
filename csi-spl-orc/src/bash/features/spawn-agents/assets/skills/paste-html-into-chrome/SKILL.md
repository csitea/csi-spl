---
name: paste-html-into-chrome
description: >
  Whenever you create, update, or hand the user an HTML file, end the
  reply with the complete HTML source so they can paste it into Chrome.
  Triggers: producing a .html file, "HTML runbook", "open in Chrome",
  cred-transfer.html, any self-contained HTML doc.
---

# /paste-html-into-chrome — end the reply with the full source of any HTML file you hand over

When you give the user an HTML file (created, updated, or just pointed at):

1. Write/save the file as usual.
2. Briefly say what it is and where it lives.
3. **End the reply** with the **entire** file in one fenced block:

```html
<!DOCTYPE html>
...full file, nothing omitted...
</html>
```

Do not stop at a path. Do not excerpt. Do not say "see the file". The user
pastes that block into Chrome (Save As `.html`, or a blank document).

Same HTML conventions still apply: numbered sections `1` / `1.1`, one command
per `<pre><code>`, wrap (`pre-wrap` / `overflow-wrap: anywhere`), inline CSS/JS.
