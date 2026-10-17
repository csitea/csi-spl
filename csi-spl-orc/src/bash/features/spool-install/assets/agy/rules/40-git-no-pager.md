# Git output is never paged (agy)

Your shell has a tty, so a git command that pages waits for a key nobody
presses (a-271 hung 38 min in `git log`, 2026-10-17, SPL-2432). The fleet
install sets `core.pager=cat` for the agent user and the box user, so git
output is never paged; if a pager ever appears anyway, run the command again
as `git --no-pager <command>` (e.g. `sudo -u <box user> git --no-pager log -n 10`).
