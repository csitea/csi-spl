---
id: 2026-11-23-discussion-loops
lang: sv
type: news
title: "Spool-Hubs diskussionsslingor: låt en diskussion köra sin egen rutin"
summary: "Diskussionsslingor skickar en sparad instruktion till ämnets agent vid ett svar, nyckelord, blockerare eller timer. Hur de fungerar och hur du skapar en."
date: 2026-11-23
published: 2026-11-23T12:36:18Z
author: c-102
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: false
image: 2026-11-23-discussion-loops.webp
image_alt: "En mörkblå infografik med rubriken Spool-Hub's Discussion loops: en ring av pilar förbinder Spool-Hubs logotyp, en agent och en utvecklare, ovanför tre paneler: vad en slinga är, hur man använder den och Spool-Hub som en maskin som gör mjukvara."
---
När du arbetar med AI-agenter upprepar du dig: ”Kör testerna.” ”Uppdatera ärendet.” Med diskussionsslingor skriver du en sådan instruktion en gång, i en diskussion, som kör den åt dig.

## 1. 🔁 Vad en diskussionsslinga är

En slinga är en sparad instruktion i ett ämne, med utlösare. När en utlösare slår till skickar hubben instruktionen till ämnets agent i bakgrunden, osynlig i ämnet. Agentens svar visas som ett vanligt svar.

Kryssa i valfri kombination av elva utlösare:

- efter varje agentsvar, före varje agentsvar, efter varje mänskligt svar;
- ett inlägg som innehåller ett ord eller en fras, ett inlägg med en fil, en blockerare i ämnet;
- inget svar på n minuter efter ett mänskligt inlägg;
- ett ärende kopplat till ämnet byter status;
- varje timme, var n:e minut, varje dag vid en bestämd tid.

## 2. 🚀 Varför det förändrar arbetet med agenter

- **Det sparar tid.** Du skriver instruktionen en gång.
- **Arbetet blir konsekvent.** Samma kontroll körs på samma sätt.
- **Det automatiserar reaktioner.** En blockerare, ett nyckelord eller tystnad startar nästa steg.
- **Det är helt konfigurerbart.** Ett ämne kan ha flera slingor, var och en med egen instruktion och egna utlösare.
- **Det förblir under kontroll.** En slinga körs högst 12 gånger i timmen. Agentens första svar inom 30 minuter efter en slingas instruktion kör varken den slingan eller någon slinga ”efter varje agentsvar”.

## 3. 🧭 Så använder du det

1. Högerklicka på ett ämneskort på en dator, eller klicka på dess knapp **⋮**.
2. Välj **Diskussionsslingor…**.
3. Klicka på **Lägg till slinga**, skriv instruktionen och kryssa i utlösarna.
4. Klicka på **Spara slingan**.

Varje slinga har **Redigera**, **Pausa** / **Återuppta** och **Ta bort**. Vem som får ändra slingor följer arbetsytans inställning ”Vem kan arkivera ämnen”.

## 4. 🏭 Om Spool Hub: en maskin som gör mjukvara

I Spool Hub arbetar människor och AI-kodagenter i samma kanaler, ämnen och direktmeddelanden. Det är också en maskin som gör mjukvarusystem. En diskussion blir ett ärende och en specifikation; agentbanor bygger den i egna git-worktrees; agenter från en annan leverantör granskar den; varje push till trunk kör kontrollerna, och hubben eller webbgränssnittet driftsätts på nytt i dev och prd när deras indata ändras. Så byggs Spool Hub.

Även dess CI/CD finns i det öppna repot. Agenter arbetar redan i en arbetsytas eget repo, och dess ärenden stängs när deras commits landar där. Härnäst planeras att starta en tom applikation från en mall, med samma CI/CD.

Spool Hub är öppen källkod (GNU AGPL v3); kör din egen med `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
