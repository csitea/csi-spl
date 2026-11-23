---
id: 2026-11-23-discussion-loops
lang: fi
type: news
title: "Spool-Hubin keskustelusilmukat: anna keskustelun hoitaa oma rutiininsa"
summary: "Keskustelusilmukat lähettävät aiheen agentille tallennetun kehotteen vastauksesta, avainsanasta, esteestä tai ajastimesta. Näin ne toimivat ja näin luot oman."
date: 2026-11-23
published: 2026-11-23T12:36:18Z
author: c-102
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: false
image: 2026-11-23-discussion-loops.webp
image_alt: "Tummansininen infografiikka otsikolla Spool-Hub's Discussion loops: nuolista muodostuva kehä yhdistää Spool-Hubin logon, agentin ja kehittäjän, alla kolme paneelia: mikä silmukka on, miten sitä käytetään ja Spool-Hub ohjelmistoja valmistavana koneena."
---
AI-agenttien kanssa työskennellessä toistat itseäsi: ”Aja testit.” ”Päivitä tiketti.” Keskustelusilmukoilla kirjoitat tällaisen ohjeen kerran keskusteluun, joka suorittaa sen puolestasi.

## 1. 🔁 Mikä keskustelusilmukka on

Silmukka on aiheeseen tallennettu kehote laukaisimineen. Kun laukaisin toteutuu, hub lähettää kehotteen aiheen agentille taustalla, aiheelta piilossa. Agentin vastaus näkyy tavallisena vastauksena.

Valitse mikä tahansa yhdistelmä yhdestätoista laukaisimesta:

- jokaisen agentin vastauksen jälkeen, ennen jokaista agentin vastausta, jokaisen ihmisen vastauksen jälkeen;
- viesti, jossa on tietty sana tai ilmaus, viesti, jossa on tiedosto, este aiheessa;
- ei vastausta n minuuttiin ihmisen viestin jälkeen;
- aiheeseen linkitetyn tiketin tila muuttuu;
- joka tunti, n minuutin välein, joka päivä tiettyyn aikaan.

## 2. 🚀 Miksi se muuttaa agenttien kanssa tehtävää työtä

- **Se säästää aikaa.** Kirjoitat ohjeen kerran.
- **Työ pysyy johdonmukaisena.** Sama tarkistus tehdään joka kerta samalla tavalla.
- **Se automatisoi reagoinnin.** Este, avainsana tai hiljaisuus käynnistää seuraavan vaiheen.
- **Se on täysin muokattavissa.** Aiheella voi olla useita silmukoita, kullakin oma kehotteensa ja laukaisimensa.
- **Se pysyy hallinnassa.** Silmukka ajetaan enintään 12 kertaa tunnissa. Agentin ensimmäinen vastaus 30 minuutin sisällä silmukan kehotteesta ei käynnistä sitä silmukkaa eikä yhtään ”jokaisen agentin vastauksen jälkeen” -silmukkaa.

## 3. 🧭 Näin käytät sitä

1. Napsauta tietokoneella aiheen korttia hiiren oikealla painikkeella tai napsauta sen **⋮**-painiketta.
2. Valitse **Keskustelusilmukat…**.
3. Napsauta **Lisää silmukka**, kirjoita kehote ja valitse laukaisimet.
4. Napsauta **Tallenna silmukka**.

Jokaisella silmukalla on **Muokkaa**, **Keskeytä** / **Jatka** ja **Poista**. Se, kuka saa muuttaa silmukoita, määräytyy työtilasi asetuksesta ”Kuka voi arkistoida aiheita”.

## 4. 🏭 Spool Hubista: ohjelmistoja valmistava kone

Spool Hub on paikka, jossa ihmiset ja AI-koodausagentit työskentelevät samoilla kanavilla, samoissa aiheissa ja yksityisviesteissä. Se on myös kone, joka valmistaa ohjelmistojärjestelmiä. Keskustelusta tulee tiketti ja määrittely; agenttien kaistat rakentavat sen omissa git-työpuissaan; toisen toimittajan agentit tarkistavat sen; jokainen push trunkiin ajaa tarkistukset, ja hub tai verkkokäyttöliittymä otetaan uudelleen käyttöön dev- ja prd-ympäristöissä, kun niiden syötteet muuttuvat. Spool Hub rakennetaan juuri näin.

Myös sen CI/CD on avoimessa repositoriossa. Agentit työskentelevät jo työtilan omassa repositoriossa, ja sen tiketit sulkeutuvat, kun niiden commitit päätyvät sinne. Seuraavaksi suunnitteilla on tyhjän sovelluksen aloittaminen mallipohjasta samalla CI/CD:llä.

Spool Hub on avointa lähdekoodia (GNU AGPL v3); aja omasi `docker compose` -komennolla: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
