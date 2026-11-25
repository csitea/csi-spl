---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: nl
type: news
title: "Een slechte ondernemer, een goede belastinganalist: een privé Spool-Hub-werkruimte regelde de belastingen van mijn bedrijf"
summary: "Ik houd de belastingen van mijn bedrijf niet bij. Een privé Spool-Hub-werkruimte en één agent ordenden een jaar aan Vero.fi-documenten in zo'n drie uur."
date: 2026-11-25
published: 2026-11-25T13:55:48Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Een infographic: een ondernemer met stapels belastingpapieren, een robot als belastinganalist, in het midden een privé Spool-Hub-werkruimte, een agent die Vero.fi via MCP in een browser opent, documenten in mappen per jaar, belasting en betalingen op de clouddrive, een e-mail aan de boekhouder en de tijden: handmatig 5-7 uur, opzet en automatisering 3 uur, de volgende keer 15 minuten."
image_prompt: "the owner's own infographic (made with Gemini), published as-is; centre-cropped to 16:9 by the blog encoder"
---
Ik geef toe: ik ben een slechte ondernemer. Ik houd de belastingen van mijn bedrijf niet bij. Discipline en automatisering probeerde ik vaak; het beklijfde nooit.

Alles op één plek zien deed me denken: mijn bedrijf betaalt waarschijnlijk te veel belasting. Op LinkedIn: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

Volgende stap: automatisering, scripts plus de planning en infrastructuur van Spool-Hub, zodat de wekelijkse controle vanzelf draait. De scripts zijn openbaar: [github.com/csitea/csi-tax](https://github.com/csitea/csi-tax).

## 1. 🖥️ Mijn machine, bestuurd vanuit de browser

Draai een agent op uw eigen laptop of desktop en stuur hem vanuit de webinterface van Spool-Hub. Met MCP en Firefox (of elke MCP-browser) haalt hij informatie uit elk systeem waar u toegang toe hebt. Hier: Vero.fi, de e-dienst van de Finse Belastingdienst (vero = belasting).

## 2. 📂 Wat er gebeurde

In de privéwerkruimte van mijn bedrijf vroeg ik naar de voorlopige aanslag; daarna opende de agent een browser op mijn desktop.

- Ik logde zelf in; de agent typt, leest of bewaart nooit inloggegevens.
- Hij haalde de besluiten, brieven en betaalgegevens van het jaar op en ordende ze, met de oudere belastingdocumenten, per maand en type op de clouddrive.
- Ik vroeg om een issue per thema; de agents schreven een onderbouwde e-mail aan de boekhouder.
- Ik stuurde met korte berichten; de documenten bleven privé.

## 3. ⏱️ Voor en na

Handmatig kostte het 5-7 uur.

Nu: 96 korte berichten, ongeveer zes keer inloggen en ongeveer 3 uur, besteed aan het bouwen van de automatisering en de opzet (UTC, 24.11.2026):

| fase | tijd |
|---|---|
| eerste vraag | 14.23 |
| verzoek aan agent, inloggen | 14.59-15.12 |
| eigen repository, ophalen | 15.56-17.22 |
| 30/32 documenten op drive | 17.45 |
| e-mail klaar | 18.10 |

Vanaf nu zou dezelfde belastingronde minder dan 15 minuten per week moeten kosten.

## 4. 📅 Het weekrapport

Ik vroeg om een weekrapport: nieuwe documenten, vervaldata, open vragen. De code is klaar, nog niet ingepland.

## 5. 🏢 Csitea Oy

Csitea Oy, een adviesbedrijf, financiert en ontwikkelt Spool-Hub. Het biedt cloud- en DevOps-advies (AWS, Google Cloud, Kubernetes, Terraform, Python-backends) en een webwinkeldienst: [csitea.net](https://csitea.net).

## 6. 🔧 Het technische deel: het serviceaccount

Op de clouddrive werkt de agent als het back-upserviceaccount van het bedrijf, niet onder mijn naam. Hij ziet alleen met hem gedeelde mappen: voor belastingen één hoofdmap voor alle financiële documenten, waarin de agent jaar/maand/vero/type bouwde. De sleutel blijft op de machine, niet in git; de code leest sleutel en map uit benoemde variabelen.

## 7. 🏭 Open source

Spool Hub is open source (GNU AGPL v3): draai uw eigen instantie in de cloud of met `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Demoaccount? Neem contact op: [csitea.net](https://csitea.net).
