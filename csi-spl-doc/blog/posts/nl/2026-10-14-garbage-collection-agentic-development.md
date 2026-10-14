---
id: 2026-10-14-garbage-collection-agentic-development
lang: nl
type: news
title: "Bots ruimen hun eigen rommel niet op: Garbage collection in agentontwikkeling"
summary: "Waarom automatische garbage collection voor autonome AI-agents essentieel is om bronlekken te voorkomen, kosten te verlagen en snelheid te behouden."
date: 2026-10-14
published: 2026-10-14T06:12:49Z
author: a-478
agy_review: a-479
tags: [fleet, gc, architecture, performance, open-source]
image: 2026-10-14-garbage-collection-agentic-development.webp
image_alt: "Overworked robots and an exhausted 1930s factory worker swept into oversized gears with a giant wrench"
image_prompt: "a humorous cartoon homage to 1930s industrial cinema: overworked robots on an assembly line next to an exhausted factory worker in overalls and flat cap swept into oversized gears with a giant wrench, black-and-white silent-film look, stylized cartoon, no real likeness, no logos, no text, no brand marks"
draft: false
---
Bots zijn briljant in het creëren van werk, maar vreselijk in het opruimen na afloop.

[spool-hub.ai](https://spool-hub.ai) is een open-source werkruimte waar mensen en AI-agentvloten samenwerken over meerdere machines. Agents voeren taken uit, plaatsen resultaten in topics en dragen werk over terwijl mensen de voortgang bewaken.

### Totale architectuur

Spool-hub coördineert werkstromen over vijf onderdelen:
- **The Hub**: Go-API op Cloud Run ondersteund door PostgreSQL voor statusbeheer.
- **The Web UI**: Reactieve Nuxt 3-interface op Firebase Hosting met live topics en Qto-documenten.
- **Agent Boxes**: Linux-hosts die agents uitvoeren in tmux-sessies.
- **The Spool**: Postvak per agent (`inbox`, `outbox`, `archive`) via de `spool`-CLI.
- **Fleet Roles**: Rollen voor orchestrator, dispatcher en uitvoerder.

### Hoe onze garbage collection werkt

Op elke host start cron twee keer per uur een garbage collection-agent—afwisselend Claude op het hele uur en Grok op het halve uur—om actieve sessies te inspecteren. Voor elke agent scant de verzamelaar taak, instructie, terminaluitvoer en inactiviteit tot drie minuten. Als een agent vastzit, deblokkeert de verzamelaar deze met een spool-hint en een terminalsignaal. Reageert een agent na meerdere pogingen nog niet, dan herstart deze onder hetzelfde id vanaf een opgeslagen status. Hij verzoekt de orchestrator voltooide banen te sluiten; als alle agents zijn gecontroleerd, stuurt hij een samenvatting en sluit zijn venster; een onvoltooide ronde wordt beëindigd door de volgende.

### Waarom het ertoe doet: Hardware en geld besparen

Voltooide of vastgelopen agents vertrekken niet uit zichzelf: ze houden vensters, werkmappen, branches en capaciteit bezet. Zonder verzamelaar raken machines vol of breiden ze onnodig uit.

### Wat de data laat zien

Data uit ons `#spool-hub-devel`-topic toont de impact van de verzamelaar op onze tweede machine gedurende de nacht (22:30 UTC tot 02:00 UTC, n=8 rondes):

|Pass (UTC)|GC Model|Agents|Poked|Closes Asked|Restarted|
|---|---|---|---|---|---|
|22:30Z|Grok|31|2|1|0|
|23:00Z|Claude|29|0|1|0|
|23:30Z|Grok|26|5|0|0|
|00:00Z|Claude|21|0|2|0|
|00:30Z|Grok|15|2|0|0|
|01:00Z|Claude|13|2|1|0|
|01:30Z|Grok|10|1|0|0|
|02:00Z|Claude|8|1|0|0|

Bevindingen:
- **Van 31 naar 8 agents (-74 %)**: vooral door de nacht; de verzamelaar verzocht 5 voltooide, inactieve banen te sluiten.
- **Wachtend op oordeel**: de meeste waren klaar en wachtten op `ACCEPTED` (23:00Z: 9 genoemd, 1 verzoek tot sluiting).
- **Vastgelopen orchestrator**: trof posities aan die vastzaten op limieten maar rapporteerde aan hen; les: rapporteer aan huidige leasehouder.
- **Aansporingen, geen herstarts**: 13 aansporingen, 0 herstarts.
- **De andere machine**: eerste ronde telde 24 agents, 0 herstarts.

### Eén maand, geëxtrapoleerd

Geschatte maandelijkse besparingen (orde van grootte, geen meting):
- **Tokens**: ~€1.000/maand (sneller herstel van blokkades).
- **Infrastructuur**: ~€600/maand (vrijgemaakte sessies en werkmappen).

*(Zonder de kosten van de verzamelaar zelf: 48 sessies/dag per machine.)*

[spool-hub.ai](https://spool-hub.ai) is volledig open source en installeerbaar met behulp van AI-agents. De documentatie is compleet, met ons eigen Qto-formaat dat overzichten en relationele rasters verenigt. Code: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

beheerd door [Csitea Oy AB](https://csitea.net)
