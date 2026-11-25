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
image_alt: "Infografikas: verslininkas su mokesčių popierių krūvomis, robotas mokesčių analitikas, centre privati Spool-Hub darbo erdvė, agentas per MCP naršyklėje atidaro Vero.fi, dokumentai debesies diske sudėti į metų, mokesčių ir mokėjimų aplankus, el. laiškas buhalteriui ir laikai: rankomis 5-7 valandos, diegimas ir automatizavimas 3 valandos, kitą kartą 15 minučių."
image_prompt: "the owner's own infographic (made with Gemini), published as-is; centre-cropped to 16:9 by the blog encoder"
---
Prisipažinsiu: esu blogas verslininkas. Nespėju sekti savo įmonės mokesčių. Daug kartų bandžiau drausmę ir automatizavimą, bet niekas neprigijo.

Pamatęs viską vienoje vietoje, pagalvojau: tikriausiai permoku savo įmonės mokesčius. LinkedIn: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

Toliau – automatizavimas: skriptai ir Spool-Hub planavimas bei infrastruktūra, kad savaitinė patikra vyktų savaime. Skriptai vieši: [github.com/csitea/csi-tax](https://github.com/csitea/csi-tax).

## 1. 🖥️ Mano kompiuteris, valdomas iš naršyklės

Paleiskite agentą savo nešiojamajame ar staliniame kompiuteryje ir valdykite jį iš Spool-Hub žiniatinklio sąsajos. Su MCP ir Firefox (ar bet kuria MCP naršykle) jis gauna informaciją iš bet kurios sistemos, prie kurios turite prieigą. Šiuo atveju – Vero.fi, Suomijos mokesčių administratoriaus e. paslauga (vero = mokestis).

## 2. 📂 Kas nutiko

Savo įmonės privačioje darbo srityje paklausiau apie avansinį mokestį, tada paprašiau agento atidaryti naršyklę mano staliniame kompiuteryje.

- Prisijungiau pats; agentas niekada neįveda, neskaito ir nesaugo prisijungimo duomenų.
- Jis gavo metų sprendimus, laiškus ir mokėjimų duomenis ir kartu su senesniais mokesčių dokumentais surūšiavo juos debesies diske pagal mėnesį ir tipą.
- Paprašiau atskiros užduoties kiekvienai temai; agentai parašė pagrįstą el. laišką buhalteriui.
- Valdžiau trumpomis žinutėmis; dokumentai liko privatūs.

## 3. ⏱️ Prieš ir po

Rankomis tai užtruko 5-7 valandas.

Dabar: 96 trumpos žinutės, apie šeši prisijungimai ir apie 3 valandos, skirtos automatizavimui ir diegimui sukurti (UTC, 24.11.2026):

| etapas | laikas |
|---|---|
| pirmas klausimas | 14.23 |
| užklausa agentui, prisijungimas | 14.59-15.12 |
| atskira saugykla, gavimas | 15.56-17.22 |
| 30/32 dokumentai diske | 17.45 |
| el. laiškas paruoštas | 18.10 |

Nuo šiol tas pats mokesčių darbas turėtų užtrukti mažiau nei 15 minučių per savaitę.

## 4. 📅 Savaitės ataskaita

Paprašiau savaitės ataskaitos: nauji dokumentai, terminai, atviri klausimai. Kodas paruoštas, bet dar nesuplanuotas.

## 5. 🏢 Csitea Oy

Csitea Oy, konsultacijų įmonė, finansuoja ir kuria Spool-Hub. Ji siūlo debesijos ir DevOps konsultacijas (AWS, Google Cloud, Kubernetes, Terraform, Python serverio sistemos) ir internetinės parduotuvės paslaugą: [csitea.net](https://csitea.net).

## 6. 🔧 Techninė dalis: paslaugos paskyra

Debesies diske agentas veikia kaip įmonės atsarginių kopijų paslaugos paskyra, o ne mano vardu. Jis mato tik su juo bendrinamus aplankus: mokesčiams – vieną šakninį aplanką visiems finansiniams dokumentams, kuriame agentas sukūrė metai/mėnuo/vero/tipas. Raktas lieka kompiuteryje, ne git; kodas raktą ir aplanką skaito iš pavadintų kintamųjų.

## 7. 🏭 Atvirasis kodas

Spool Hub yra atvirojo kodo (GNU AGPL v3): paleiskite savo egzempliorių debesyje arba su `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Norite demonstracinės paskyros? Susisiekite: [csitea.net](https://csitea.net).
