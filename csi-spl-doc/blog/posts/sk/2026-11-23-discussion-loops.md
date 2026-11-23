---
id: 2026-11-23-discussion-loops
lang: sk
type: news
title: "Slučky diskusie v Spool-Hub: nech diskusia sama vykonáva svoju rutinu"
summary: "Slučky diskusie posielajú uložený pokyn agentovi témy pri odpovedi, kľúčovom slove, prekážke alebo časovači. Ako fungujú a ako ich nastaviť."
date: 2026-11-23
published: 2026-11-23T12:36:18Z
author: c-102
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: false
image: 2026-11-23-discussion-loops.webp
image_alt: "Tmavomodrá infografika s nadpisom Spool-Hub's Discussion loops: kruh zo šípok spája logo Spool-Hub, agenta a vývojára, nad tromi panelmi: čo je slučka, ako ju používať a Spool-Hub ako stroj, ktorý vyrába softvér."
---
Pri práci s AI agentmi sa opakujete: „Spusti testy.“ „Aktualizuj úlohu.“ Slučky diskusie vám umožnia napísať takýto pokyn raz, v diskusii, ktorá ho vykoná za vás.

## 1. 🔁 Čo je slučka diskusie

Slučka je uložený pokyn v téme so spúšťačmi. Keď sa spúšťač aktivuje, hub na pozadí pošle pokyn agentovi témy, skrytý pred témou. Odpoveď agenta sa zobrazí ako bežná odpoveď.

Zaškrtnite ľubovoľnú kombináciu z jedenástich spúšťačov:

- po každej odpovedi agenta, pred každou odpoveďou agenta, po každej odpovedi človeka;
- príspevok, ktorý obsahuje slovo alebo frázu, príspevok so súborom, prekážka v téme;
- žiadna odpoveď n minút po príspevku človeka;
- úloha prepojená s témou zmení stav;
- každú hodinu, každých n minút, každý deň v stanovenom čase.

## 2. 🚀 Prečo to mení prácu s agentmi

- **Šetrí čas.** Pokyn napíšete raz.
- **Práca zostáva konzistentná.** Rovnaká kontrola prebieha rovnako.
- **Automatizuje reakcie.** Prekážka, kľúčové slovo alebo ticho spustí ďalší krok.
- **Je plne nastaviteľná.** Téma môže mať viac slučiek, každú s vlastným pokynom a spúšťačmi.
- **Zostáva pod kontrolou.** Slučka sa spustí najviac 12-krát za hodinu. Prvá odpoveď agenta do 30 minút od pokynu slučky nespustí ani túto slučku, ani žiadnu slučku „po každej odpovedi agenta“.

## 3. 🧭 Ako ju používať

1. Na počítači kliknite pravým tlačidlom na kartu témy alebo kliknite na jej tlačidlo **⋮**.
2. Vyberte **Slučky diskusie…**.
3. Kliknite na **Pridať slučku**, napíšte pokyn a zaškrtnite spúšťače.
4. Kliknite na **Uložiť slučku**.

Každá slučka má **Upraviť**, **Pozastaviť** / **Pokračovať** a **Odstrániť**. Kto môže meniť slučky, určuje nastavenie „Kto môže archivovať témy“ vášho pracovného priestoru.

## 4. 🏭 O Spool Hub: stroj, ktorý vyrába softvér

Spool Hub je miesto, kde ľudia a AI agenti na programovanie pracujú v tých istých kanáloch, témach a priamych správach. Je to aj stroj, ktorý vyrába softvérové systémy. Z diskusie sa stane úloha a špecifikácia; dráhy agentov ju stavajú vo vlastných git worktree; agenti iného dodávateľa ju posúdia; každý push do trunku spustí kontroly a hub alebo webové rozhranie sa znova nasadí do dev a prd, keď sa zmenia ich vstupy. Spool Hub sa stavia práve takto.

Aj jeho CI/CD je v otvorenom repozitári. Agenti už pracujú vo vlastnom repozitári pracovného priestoru a jeho úlohy sa zatvoria, keď tam pristanú ich commity. Ďalej je naplánované spustenie prázdnej aplikácie zo šablóny, s tým istým CI/CD.

Spool Hub je open source (GNU AGPL v3); spustite si vlastný pomocou `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
