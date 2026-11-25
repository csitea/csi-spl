---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: lt
type: news
title: "Blogas verslininkas, geras mokesčių analitikas: privati Spool-Hub darbo sritis sutvarkė mano įmonės mokesčius"
summary: "Nespėju sekti savo įmonės mokesčių. Privati Spool-Hub darbo sritis ir vienas agentas per maždaug tris valandas sutvarkė metų Vero.fi dokumentus."
date: 2026-11-25
published: 2026-11-25T13:55:48Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Terminalo langas, kuriame agentas ieško mokesčių failų įmonės debesies diske; paslaugos paskyros pavadinimas, keliai, identifikatoriai ir aplankų pavadinimai uždengti juodais stačiakampiais."
image_prompt: "a screenshot of the agent's terminal and its side panel on a desktop, private details covered with solid black boxes, cropped to 16:9; not generated"
---
Prisipažinsiu: esu blogas verslininkas. Nespėju sekti savo įmonės mokesčių. Daug kartų bandžiau drausmę ir automatizavimą, bet niekas neprigijo.

Pamatęs viską vienoje vietoje, pagalvojau: tikriausiai permoku savo įmonės mokesčius. LinkedIn: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

## 1. 🖥️ Mano kompiuteris, valdomas iš naršyklės

Paleiskite agentą savo nešiojamajame ar staliniame kompiuteryje ir valdykite jį iš Spool-Hub žiniatinklio sąsajos. Su MCP ir Firefox (ar bet kuria MCP naršykle) jis gauna informaciją iš bet kurios sistemos, prie kurios turite prieigą. Šiuo atveju – Vero.fi, Suomijos mokesčių administratoriaus e. paslauga (vero = mokestis).

## 2. 📂 Kas nutiko

Savo įmonės privačioje darbo srityje paklausiau apie avansinį mokestį, tada paprašiau agento atidaryti naršyklę mano staliniame kompiuteryje.

- Prisijungiau pats; agentas niekada neįveda, neskaito ir nesaugo prisijungimo duomenų.
- Jis gavo metų sprendimus, laiškus ir mokėjimų duomenis ir kartu su senesniais mokesčių dokumentais surūšiavo juos debesies diske pagal mėnesį ir tipą.
- Paprašiau atskiros užduoties kiekvienai temai; agentai parašė pagrįstą el. laišką buhalteriui.
- Valdžiau trumpomis žinutėmis; dokumentai liko privatūs.

## 3. ⏱️ Prieš ir po

Rankomis, mano vertinimu (nematuota): 5-7 valandos. Apie 30 dokumentų sutvarkymas (po 3-5 min.), mokėjimai ir terminai (1-2 h), seni failai (1 h), el. laiškas (1 h).

Dabar: 96 trumpos žinutės, apie šeši prisijungimai, apie 3 valandos diegimo (UTC, 24.11.2026):

| etapas | laikas |
|---|---|
| pirmas klausimas | 14.23 |
| užklausa agentui, prisijungimas | 14.59-15.12 |
| atskira saugykla, gavimas | 15.56-17.22 |
| 30/32 dokumentai diske | 17.45 |
| el. laiškas paruoštas | 18.10 |

Nuo užklausos iki pabaigos: 2 h 46 min; nuo klausimo iki el. laiško: 3 h 47 min.

## 4. 📅 Savaitės ataskaita

Paprašiau savaitės ataskaitos: nauji dokumentai, terminai, atviri klausimai. Kodas paruoštas, bet dar nesuplanuotas.

## 5. 🏢 Csitea Oy

Csitea Oy, konsultacijų įmonė, finansuoja ir kuria Spool-Hub. Ji siūlo debesijos ir DevOps konsultacijas (AWS, Google Cloud, Kubernetes, Terraform, Python serverio sistemos) ir internetinės parduotuvės paslaugą: [csitea.net](https://csitea.net).

## 6. 🔧 Techninė dalis: paslaugos paskyra

Debesies diske agentas veikia kaip įmonės atsarginių kopijų paslaugos paskyra, o ne mano vardu. Jis mato tik su juo bendrinamus aplankus: mokesčiams – vieną šakninį aplanką visiems finansiniams dokumentams, kuriame agentas sukūrė metai/mėnuo/vero/tipas. Raktas lieka kompiuteryje, ne git; kodas raktą ir aplanką skaito iš pavadintų kintamųjų.

## 7. 🏭 Atvirasis kodas

Spool Hub yra atvirojo kodo (GNU AGPL v3): paleiskite savo egzempliorių debesyje arba su `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Norite demonstracinės paskyros? Susisiekite: [csitea.net](https://csitea.net).
