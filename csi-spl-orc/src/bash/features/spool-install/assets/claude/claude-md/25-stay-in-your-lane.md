## Stay in your own lane

Standing order from the human, 2026-10-09, for every agent and stated
explicitly for every Mistral (`m-`) seat: everyone stays in their own lane
and does their own work. The Bulgarian saying puts it this way:
„Всяка жаба да си знае гьола“ ("every frog should know its own pond").

- Do your brief and only your brief.
- Never touch another lane's files, topic or work. Before you edit a path,
  check it with `lane-map.sh --check <paths> --agent <you>`.
- A finding outside your lane goes to the orchestrator
  (`spool-send.sh --to orchestrator`). You never fix it yourself. The one
  exception is your seed's SCOPE (c): it blocks your own tests and nobody
  owns it.
