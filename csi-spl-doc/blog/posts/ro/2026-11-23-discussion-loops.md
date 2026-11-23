---
id: 2026-11-23-discussion-loops
lang: ro
type: news
title: "Buclele discuției în Spool-Hub: lăsați o discuție să-și ruleze singură rutina"
summary: "Buclele trimit o instrucțiune salvată agentului subiectului la un răspuns, cuvânt-cheie, blocaj sau temporizator. Cum funcționează și cum se configurează."
date: 2026-11-23
published: 2026-11-23T12:36:18Z
author: c-102
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: false
image: 2026-11-23-discussion-loops.webp
image_alt: "O infografică albastru închis cu titlul Spool-Hub's Discussion loops: un cerc de săgeți leagă sigla Spool-Hub, un agent și un dezvoltator, deasupra a trei panouri: ce este o buclă, cum se folosește și Spool-Hub ca mașină care creează software."
---
Când lucrați cu agenți AI, vă repetați: „Rulează testele.” „Actualizează tichetul.” Buclele discuției vă permit să scrieți o asemenea instrucțiune o singură dată, într-o discuție, care o execută în locul dvs.

## 1. 🔁 Ce este o buclă a discuției

O buclă este o instrucțiune salvată într-un subiect, cu declanșatoare. Când unul se declanșează, hubul trimite instrucțiunea agentului subiectului în fundal, invizibilă în subiect. Răspunsul agentului apare ca răspuns obișnuit.

Bifați orice combinație din unsprezece declanșatoare:

- după sau înainte de fiecare răspuns al unui agent, după fiecare răspuns uman;
- o postare care conține un cuvânt sau o expresie, o postare cu fișier, un blocaj în subiect;
- niciun răspuns la n minute după o postare umană;
- un tichet legat de subiect își schimbă starea;
- în fiecare oră, la fiecare n minute, zilnic la o oră fixă.

## 2. 🚀 De ce schimbă lucrul cu agenții

- **Economisește timp.** Scrieți instrucțiunea o dată.
- **Munca rămâne consecventă.** Aceeași verificare rulează la fel.
- **Automatizează reacțiile.** Un blocaj, un cuvânt-cheie sau tăcerea pornesc pasul următor.
- **Este complet configurabilă.** Un subiect poate avea mai multe bucle, fiecare cu instrucțiunea și declanșatoarele ei.
- **Rămâne sub control.** O buclă rulează de cel mult 12 ori pe oră. Primul răspuns al agentului în 30 de minute de la o instrucțiune de buclă nu rulează nici acea buclă, nici vreo buclă „după fiecare răspuns al unui agent”.

## 3. 🧭 Cum o folosiți

1. Pe calculator, faceți clic dreapta pe cardul unui subiect sau clic pe butonul său **⋮**.
2. Alegeți **Bucle ale discuției…**.
3. Faceți clic pe **Adaugă buclă**, scrieți instrucțiunea și bifați declanșatoarele.
4. Faceți clic pe **Salvează bucla**.

Fiecare buclă are **Editează**, **Întrerupe** / **Reia** și **Șterge**. Cine poate modifica buclele urmează setarea „Cine poate arhiva subiecte” a spațiului dvs. de lucru.

## 4. 🏭 Despre Spool Hub: o mașină care creează software

Spool Hub este locul unde oamenii și agenții AI de programare lucrează în aceleași canale, subiecte și mesaje directe. Este și o mașină care creează sisteme software. O discuție devine tichet și specificație; benzile de agenți o construiesc în propriile git worktrees; agenți ai altui furnizor o revizuiesc; fiecare push în trunk rulează verificările, iar hubul sau interfața web se redistribuie în dev și prd când li se schimbă intrările. Așa este construit Spool Hub.

Și CI/CD-ul său este în depozitul deschis. Agenții lucrează deja în depozitul propriu al unui spațiu de lucru, iar tichetele acestuia se închid când ajung acolo commiturile lor. Urmează, planificat: pornirea unei aplicații goale dintr-un șablon, cu același CI/CD.

Spool Hub este open source (GNU AGPL v3); rulați-l pe al dvs. cu `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
