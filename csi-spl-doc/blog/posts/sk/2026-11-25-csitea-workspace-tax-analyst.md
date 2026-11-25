---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: sk
type: news
title: "Zlý podnikateľ, dobrý daňový analytik: súkromný pracovný priestor Spool-Hub vybavil dane mojej firmy"
summary: "Nestíham sledovať dane svojej firmy. Súkromný pracovný priestor Spool-Hub a jeden agent dali do poriadku ročné dokumenty z Vero.fi asi za tri hodiny."
date: 2026-11-25
published: 2026-11-25T13:55:48Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Infografika: podnikateľ s kopami daňových papierov, robot ako daňový analytik, v strede súkromný pracovný priestor Spool-Hub, agent otvára Vero.fi v prehliadači cez MCP, dokumenty v priečinkoch podľa roka, daní a platieb na cloudovom disku, e-mail účtovníkovi a časy: ručne 5-7 hodín, nastavenie a automatizácia 3 hodiny, nabudúce 15 minút."
image_prompt: "the owner's own infographic (made with Gemini), published as-is; centre-cropped to 16:9 by the blog encoder"
---
Priznávam: som zlý podnikateľ. Nestíham sledovať dane svojej firmy. Mnohokrát som skúšal disciplínu aj automatizáciu; nikdy sa to neudržalo.

Keď som všetko videl na jednom mieste, napadlo mi: dane svojej firmy asi preplácam. Na LinkedIn: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

Ďalej automatizácia: skripty s plánovaním a infraštruktúrou Spool-Hubu, aby týždenná kontrola bežala sama. Skripty sú verejné: [github.com/csitea/csi-tax](https://github.com/csitea/csi-tax).

## 1. 🖥️ Môj počítač, ovládaný z prehliadača

Spustite agenta na vlastnom notebooku alebo stolnom počítači a ovládajte ho z webového rozhrania Spool-Hub. S MCP a Firefoxom (alebo akýmkoľvek MCP prehliadačom) získa informácie z akéhokoľvek systému, ku ktorému máte prístup. Tu to bol Vero.fi, elektronická služba fínskej daňovej správy (vero = daň).

## 2. 📂 Čo sa stalo

V súkromnom pracovnom priestore mojej firmy som sa spýtal na preddavok na daň a potom som nechal agenta otvoriť prehliadač na mojom počítači.

- Prihlásil som sa sám; agent nikdy nezadáva, nečíta ani neukladá prihlasovacie údaje.
- Stiahol rozhodnutia, listy a platobné údaje za rok a spolu so staršími daňovými dokumentmi ich uložil na cloudový disk podľa mesiaca a typu.
- Požiadal som o úlohu ku každej téme; agenti napísali odôvodnený e-mail účtovníkovi.
- Riadil som to krátkymi správami; dokumenty zostali súkromné.

## 3. ⏱️ Pred a po

Ručne to trvalo 5-7 hodín.

Teraz: 96 krátkych správ, asi šesť prihlásení a asi 3 hodiny, ktoré padli na vybudovanie automatizácie a nastavenia (UTC, 24.11.2026):

| fáza | čas |
|---|---|
| prvá otázka | 14.23 |
| požiadavka na agenta, prihlásenie | 14.59-15.12 |
| vlastný repozitár, sťahovanie | 15.56-17.22 |
| 30/32 dokumentov na disku | 17.45 |
| e-mail hotový | 18.10 |

Odteraz by rovnaká daňová agenda mala trvať menej ako 15 minút týždenne.

## 4. 📅 Týždenný report

Požiadal som o týždenný report: nové dokumenty, termíny, otvorené otázky. Kód je hotový, zatiaľ nie je naplánovaný.

## 5. 🏢 Csitea Oy

Csitea Oy, konzultačná firma, financuje a vyvíja Spool-Hub. Ponúka konzultácie v oblasti cloudu a DevOps (AWS, Google Cloud, Kubernetes, Terraform, backendy v Pythone) a službu internetového obchodu: [csitea.net](https://csitea.net).

## 6. 🔧 Technická časť: servisný účet

Na cloudovom disku agent pracuje ako záložný servisný účet firmy, nie ako ja. Vidí len priečinky, ktoré s ním boli zdieľané: pre dane jeden koreňový priečinok pre všetky finančné dokumenty, kde agent vytvoril štruktúru rok/mesiac/vero/typ. Kľúč zostáva na počítači, nie v gite; kód číta kľúč a priečinok z pomenovaných premenných.

## 7. 🏭 Open source

Spool Hub je open source (GNU AGPL v3): spustite si vlastnú inštanciu v cloude alebo pomocou `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Chcete demo účet? Kontaktujte nás: [csitea.net](https://csitea.net).
