---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: sk
type: news
title: "Zlý podnikateľ, dobrý daňový analytik: súkromný pracovný priestor Spool-Hub vybavil dane mojej firmy"
summary: "Nestíham sledovať dane svojej firmy. Súkromný pracovný priestor Spool-Hub a jeden agent dali do poriadku ročné dokumenty z Vero.fi asi za tri hodiny."
date: 2026-11-25
published: 2026-11-25T13:03:57Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Okno terminálu, v ktorom agent hľadá daňové súbory na cloudovom disku firmy; názov servisného účtu, cesty, identifikátory a názvy priečinkov sú zakryté čiernymi obdĺžnikmi."
image_prompt: "a screenshot of the agent's terminal and its side panel on a desktop, private details covered with solid black boxes, cropped to 16:9; not generated"
---
Priznávam: som zlý podnikateľ. Nestíham sledovať dane svojej firmy. Mnohokrát som skúšal disciplínu aj automatizáciu; nikdy sa to neudržalo.

Keď som všetko videl na jednom mieste, napadlo mi: dane svojej firmy asi preplácam. Na LinkedIn: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

## 1. 🖥️ Môj počítač, ovládaný z prehliadača

Spustite agenta na vlastnom notebooku alebo stolnom počítači a ovládajte ho z webového rozhrania Spool-Hub. S MCP a Firefoxom (alebo akýmkoľvek MCP prehliadačom) získa informácie z akéhokoľvek systému, ku ktorému máte prístup. Tu to bol Vero.fi, elektronická služba fínskej daňovej správy (vero = daň).

## 2. 📂 Čo sa stalo

V súkromnom pracovnom priestore mojej firmy som sa spýtal na preddavok na daň a potom som nechal agenta otvoriť prehliadač na mojom počítači.

- Prihlásil som sa sám; agent nikdy nezadáva, nečíta ani neukladá prihlasovacie údaje.
- Stiahol rozhodnutia, listy a platobné údaje za rok a spolu so staršími daňovými dokumentmi ich uložil na cloudový disk podľa mesiaca a typu.
- Požiadal som o úlohu ku každej téme; agenti napísali odôvodnený e-mail účtovníkovi.
- Riadil som to krátkymi správami; dokumenty zostali súkromné.

## 3. ⏱️ Pred a po

Ručne, podľa môjho odhadu (nemerané): 5-7 hodín. Asi 30 zaradených dokumentov (3-5 min každý), platby a termíny splatnosti (1-2 h), staré súbory (1 h), e-mail (1 h).

Teraz: 96 krátkych správ, asi šesť prihlásení, asi 3 hodiny nastavovania (UTC, 24.11.2026):

| fáza | čas |
|---|---|
| prvá otázka | 14.23 |
| požiadavka na agenta, prihlásenie | 14.59-15.12 |
| vlastný repozitár, sťahovanie | 15.56-17.22 |
| 30/32 dokumentov na disku | 17.45 |
| e-mail hotový | 18.10 |

Od požiadavky po hotovo: 2 h 46 min; od otázky po e-mail: 3 h 47 min.

## 4. 📅 Týždenný report

Požiadal som o týždenný report: nové dokumenty, termíny, otvorené otázky. Kód je hotový, zatiaľ nie je naplánovaný.

## 5. 🏢 Csitea Oy

Csitea Oy, konzultačná firma, financuje a vyvíja Spool-Hub. Ponúka konzultácie v oblasti cloudu a DevOps (AWS, Google Cloud, Kubernetes, Terraform, backendy v Pythone) a službu internetového obchodu: [csitea.net](https://csitea.net).

## 6. 🔧 Technická časť: servisný účet

Na cloudovom disku agent pracuje ako záložný servisný účet firmy, nie ako ja. Vidí len priečinky, ktoré s ním boli zdieľané: pre dane jeden koreňový priečinok pre všetky finančné dokumenty, kde agent vytvoril štruktúru rok/mesiac/vero/typ. Kľúč zostáva na počítači, nie v gite; kód číta kľúč a priečinok z pomenovaných premenných.

## 7. 🏭 Open source

Spool Hub je open source (GNU AGPL v3): spustite si vlastnú inštanciu v cloude alebo pomocou `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Chcete demo účet? Kontaktujte nás: [csitea.net](https://csitea.net).
