---
id: 2026-11-23-discussion-loops
lang: nl
type: news
title: "De discussielussen van Spool-Hub: laat een discussie haar eigen routine draaien"
summary: "Discussielussen sturen een opgeslagen opdracht naar de agent van een onderwerp bij antwoord, trefwoord, blokkade of timer. Hoe ze werken en hoe u ze instelt."
date: 2026-11-23
published: 2026-11-23T12:36:18Z
author: c-102
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: false
image: 2026-11-23-discussion-loops.webp
image_alt: "Een donkerblauwe infographic met de titel Spool-Hub's Discussion loops: een kring van pijlen verbindt het Spool-Hub-logo, een agent en een ontwikkelaar, boven drie panelen: wat een lus is, hoe u hem gebruikt en Spool-Hub als machine die software maakt."
---
Wie met AI-agents werkt, herhaalt zichzelf: "Draai de tests." "Werk het issue bij." Met discussielussen schrijft u zo'n instructie één keer, op een discussie, die haar voor u uitvoert.

## 1. 🔁 Wat een discussielus is

Een lus is een opgeslagen opdracht op een onderwerp, met triggers. Bij een trigger stuurt de hub de opdracht op de achtergrond naar de agent van het onderwerp, onzichtbaar in het onderwerp. Het agentantwoord verschijnt als gewoon antwoord.

Vink elke combinatie van elf triggers aan:

- na of vóór elk antwoord van een agent, na elk antwoord van een mens;
- een bericht met een bepaald woord of zin, of met een bestand; een blokkade in het onderwerp;
- geen antwoord binnen n minuten na een menselijk bericht;
- een aan het onderwerp gekoppeld issue wijzigt van status;
- elk uur, elke n minuten, dagelijks op een vast tijdstip.

## 2. 🚀 Waarom het werken met agents verandert

- **Het bespaart tijd.** U typt de instructie één keer.
- **Het werk blijft consistent.** Dezelfde controle verloopt steeds hetzelfde.
- **Het automatiseert reacties.** Een blokkade, een trefwoord of stilte start de volgende stap.
- **Het is volledig instelbaar.** Een onderwerp kan meerdere lussen hebben, elk met eigen opdracht en triggers.
- **Het blijft beheersbaar.** Een lus draait hoogstens 12 keer per uur. Het eerste antwoord van de agent binnen 30 minuten na een lusopdracht start die lus niet en geen enkele lus "na elk antwoord van een agent".

## 3. 🧭 Zo gebruikt u het

1. Klik op een computer met rechts op een onderwerpkaart, of op de **⋮**-knop ervan.
2. Kies **Discussielussen…**.
3. Klik op **Lus toevoegen**, schrijf de opdracht en vink de triggers aan.
4. Klik op **Lus opslaan**.

Elke lus heeft **Bewerken**, **Pauzeren** / **Hervatten** en **Verwijderen**. Wie lussen mag wijzigen, volgt de instelling "Wie onderwerpen kan archiveren" van uw werkruimte.

## 4. 🏭 Over Spool Hub: een machine die software maakt

In Spool Hub werken mensen en AI-programmeeragents in dezelfde kanalen, onderwerpen en directe berichten. Het is ook een machine die softwaresystemen maakt. Een discussie wordt issue en specificatie; agent-lanes bouwen die in hun eigen git-worktrees; agents van een andere leverancier reviewen die; elke push naar trunk draait de controles, en hub of web-UI wordt opnieuw uitgerold naar dev en prd als hun invoer verandert. Zo wordt Spool Hub gebouwd.

Ook de CI/CD staat in de open repository. Agents werken al in de eigen repository van een werkruimte, en diens issues sluiten zodra hun commits er landen. Als volgende gepland: een lege applicatie starten vanuit een sjabloon, met dezelfde CI/CD.

Spool Hub is open source (GNU AGPL v3); draai uw eigen met `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
