---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: ro
type: news
title: "Un antreprenor slab, un analist fiscal bun: un spațiu de lucru privat Spool-Hub s-a ocupat de impozitele firmei mele"
summary: "Nu țin pasul cu impozitele firmei mele. Un spațiu de lucru privat Spool-Hub și un agent au ordonat documentele Vero.fi ale unui an în circa trei ore."
date: 2026-11-25
published: 2026-11-25T13:03:57Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "O fereastră de terminal în care un agent caută fișiere fiscale pe drive-ul cloud al firmei; numele contului de serviciu, căile, id-urile și numele folderelor sunt acoperite cu dreptunghiuri negre."
image_prompt: "a screenshot of the agent's terminal and its side panel on a desktop, private details covered with solid black boxes, cropped to 16:9; not generated"
---
Recunosc: sunt un antreprenor slab. Nu țin pasul cu impozitele firmei mele. Am încercat des disciplina și automatizarea; n-a ținut niciodată.

Văzând totul la un loc, m-am gândit: probabil plătesc impozite prea mari pentru firmă. Pe LinkedIn: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

## 1. 🖥️ Mașina mea, condusă din browser

Rulați un agent pe propriul laptop sau desktop și conduceți-l din interfața web Spool-Hub. Cu MCP și Firefox (sau orice browser MCP), preia informații din orice sistem la care aveți acces. Aici: Vero.fi, serviciul electronic al Administrației Fiscale finlandeze (vero = impozit).

## 2. 📂 Ce s-a întâmplat

În spațiul de lucru privat al firmei mele am întrebat despre impozitul anticipat, apoi am cerut agentului să deschidă un browser pe desktopul meu.

- M-am autentificat singur; agentul nu tastează, nu citește și nu stochează niciodată datele de autentificare.
- A preluat deciziile, scrisorile și datele de plată ale anului și le-a ordonat, împreună cu documentele fiscale mai vechi, pe drive-ul cloud, pe lună și tip.
- Am cerut câte un tichet pe temă; agenții au scris un e-mail argumentat către contabil.
- Am condus cu mesaje scurte; documentele au rămas private.

## 3. ⏱️ Înainte și după

Manual, după estimarea mea (nemăsurată): 5-7 ore. Circa 30 de documente arhivate (3-5 min fiecare), plăți și scadențe (1-2 h), fișiere vechi (1 h), e-mailul (1 h).

Acum: 96 de mesaje scurte, circa șase autentificări, circa 3 ore de configurare (UTC, 24.11.2026):

| fază | oră |
|---|---|
| prima întrebare | 14.23 |
| cerere către agent, autentificare | 14.59-15.12 |
| depozit propriu, preluare | 15.56-17.22 |
| 30/32 documente pe drive | 17.45 |
| e-mail gata | 18.10 |

De la cerere la final: 2 h 46 min; de la întrebare la e-mail: 3 h 47 min.

## 4. 📅 Raportul săptămânal

Am cerut un raport săptămânal: documente noi, scadențe, întrebări deschise. Codul e gata, încă neprogramat.

## 5. 🏢 Csitea Oy

Csitea Oy, o firmă de consultanță, finanțează și dezvoltă Spool-Hub. Oferă consultanță cloud și DevOps (AWS, Google Cloud, Kubernetes, Terraform, backenduri Python) și un serviciu de magazin online: [csitea.net](https://csitea.net).

## 6. 🔧 Partea tehnică: contul de serviciu

Pe drive-ul cloud, agentul lucrează ca contul de serviciu pentru backup al firmei, nu în numele meu. Vede doar folderele partajate cu el: pentru impozite, un folder rădăcină pentru toate documentele financiare, unde agentul a construit an/lună/vero/tip. Cheia rămâne pe mașină, nu în git; codul citește cheia și folderul din variabile denumite.

## 7. 🏭 Open source

Spool Hub este open source (GNU AGPL v3): rulați propria instanță în cloud sau cu `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Cont demo? Scrieți-ne: [csitea.net](https://csitea.net).
