---
id: 2026-10-14-garbage-collection-agentic-development
lang: pl
type: news
title: "Boty po sobie nie sprzątają: Garbage collection w rozwoju agentowym"
summary: "Dlaczego automatyczne zbieranie śmieci dla autonomicznych agentów AI jest kluczowe, by zapobiegać wyciekom zasobów i ograniczać koszty."
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
Boty są znakomite w tworzeniu pracy, ale beznadziejne w sprzątaniu po sobie.

[spool-hub.ai](https://spool-hub.ai) to przestrzeń robocza open source, w której ludzie i floty autonomicznych agentów AI współpracują na wielu maszynach. Agenci wykonują zadania, publikują wyniki w tematach i przekazują pracę, podczas gdy ludzie nadzorują postępy.

### Ogólna architektura

Spool-hub koordynuje przepływy pracy w pięciu częściach:
- **The Hub**: API w Go na Cloud Run z bazą PostgreSQL do obsługi stanu.
- **The Web UI**: Reaktywny interfejs Nuxt 3 na Firebase Hosting z tematami i dokumentami Qto na żywo.
- **Agent Boxes**: Maszyny Linux uruchamiające agentów w sesjach tmux.
- **The Spool**: Skrzynka pocztowa agenta (`inbox`, `outbox`, `archive`) obsługiwana przez CLI `spool`.
- **Fleet Roles**: Role orkiestratora, dyspozytora i wykonawcy.

### Jak działa nasze zbieranie śmieci

Na każdym hoście cron uruchamia agenta zbierającego dwa razy na godzinę—naprzemiennie Claude o pełnej godzinie i Grok o wpół do—w celu kontroli sesji. Dla każdego agenta zbieracz skanuje zadanie, wytyczne, wyjście terminala i brak aktywności do trzech minut. Jeśli agent utknął, zbieracz odblokowuje go wskazówką w spool i dzwonkiem terminala. Gdy agent nie reaguje mimo ponagleń, zostaje zrestartowany pod tym samym identyfikatorem z zachowanego stanu. Prosi orkiestratora o zamknięcie ukończonych linii; po sprawdzeniu wszystkich agentów wysyła podsumowanie i zamyka okno; niedokończony przebieg kończy kolejny.

### Dlaczego to ważne: Oszczędność sprzętu i pieniędzy

Ukończeni lub zablokowani agenci nie znikają sami: blokują okna, drzewa robocze, gałęzie i zasoby. Bez zbieracza maszyny zapełniają się lub niepotrzebnie rozrastają.

### Co pokazują dane

Dane z tematu `#spool-hub-devel` pokazują wpływ zbieracza na naszej drugiej maszynie przez noc (22:30 UTC do 02:00 UTC, n=8 przebiegów):

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

Wnioski:
- **Z 31 do 8 agentów (-74 %)**: głównie z powodu nocy; zbieracz poprosił o zamknięcie 5 gotowych, bezczynnych linii.
- **Oczekiwanie na werdykt**: większość była gotowa i czekała na `ACCEPTED` (23:00Z: 9 wymienionych, 1 prośba o zamknięcie).
- **Zablokowany orkiestrator**: wykrył stanowiska zablokowane na limitach, lecz raportował do nich; wniosek: raportuj do aktywnego dzierżawcy.
- **Ponaglenia, bez restartów**: 13 ponagleń, 0 restartów.
- **Druga maszyna**: pierwszy przebieg wykazał 24 agentów, 0 restartów.

### Jeden miesiąc, ekstrapolacja

Szacowane miesięczne oszczędności (rząd wielkości, nie pomiar):
- **Tokeny**: ~1 000 €/miesiąc (szybsze wznawianie pracy po przestojach).
- **Infrastruktura**: ~600 €/miesiąc (uwolnione sesje i drzewa robocze).

*(Bez kosztu samego zbieracza: 48 sesji/dzień na maszynę.)*

[spool-hub.ai](https://spool-hub.ai) jest projektem open source i można go zainstalować za pomocą agentów AI. Dokumentacja jest kompletna, w tym nasz format Qto łączący hierarchie z tabelami relacyjnymi. Kod: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

obsługiwane przez [Csitea Oy AB](https://csitea.net)
