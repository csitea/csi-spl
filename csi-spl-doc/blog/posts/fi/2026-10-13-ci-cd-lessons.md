---
id: 2026-10-13-ci-cd-lessons
lang: fi
type: news
title: "Mitä eilinen CI/CD-ongelma opetti meille"
summary: "Uusien toimintojen pysäyttäminen CI/CD:n korjaamiseksi ja testien refaktorointi lyhensivät ajoaikoja ja nopeuttivat tulevaa kehitystä."
date: 2026-10-13
published: 2026-10-13T06:04:11Z
author: a-366
agy_review: a-366
tags: [cicd, refactoring, quality, testing, performance]
image: 2026-10-13-ci-cd-lessons.webp
image_alt: "Futuristinen automatisoitu jatkuvan integroinnin ja toimituksen liukuhihna robottikäsivarsilla ja vihreillä valintamerkeillä."
image_prompt: "a futuristic automated pipeline with robotic arms, circuit boards, glowing tracks, green checkmarks, and digital interface nodes, digital art, no logos"
draft: false
---
Lokakuun 12. päivänä 2026 jatkuvan integraation putkemme kohtasi vakavia vaikeuksia. Päähaara oli useammin punainen kuin vihreä: master-haaran 22 valmistuneesta laatuajosta 10 oli vihreitä ja 12 punaisia, ja 36 ajoa peruttiin uudempien kooditoimitusten vuoksi. Palautteen saaminen kesti 47-61 minuuttia toimitusta kohden, ja verkkokäyttöliittymän julkaisut dev- ja prd-ympäristöissä seisoivat noin kaksi tuntia. Erityisesti suurin osa punaisista ajoista johtui epävakaista testeistä ja kilpatilanteista, ei varsinaisista tuotevirheistä.

Kun päähaara rikkoutuu, jokainen kaluston aktiivinen työkaista kärsii. Uusien muutosten vieminen punaiseen haaraan sokeuttaa kehittäjät ja moninkertaistaa virheet. Projektin omistaja päätti keskeyttää kaiken uusien ominaisuuksien kehittämisen ja kokeellisen refaktoroinnin, kunnes integraatio saataisiin vakaaksi ja nopeaksi. Se tarkoitti hitaamman aamupäivän hyväksymistä vastineeksi huomattavasti nopeammista ja luotettavammista päivistä jatkossa.

Keskityimme todellisiin pullonkauloihin. Ensinnäkin testien siirtäminen GitHubin isännöimille suorittimille lyhensi kokonaisajoajan noin 50 minuutista 30.4 minuutin mediaaniin (n=12), poistaen jonotusajat 19 minuutista alle 0.1 minuuttiin. Toiseksi laatuportti päivitettiin testaamaan vain muutettuja osia, nojautuen kunkin työn viimeisimpään vihreään ajoon sokean uudelleentestauksen sijaan. Kolmanneksi nopeat paikalliset tarkistukset ennen toimitusta karsivat yksinkertaiset virheet sekunneissa. Suorittimien vaihdon jälkeen kohdennetut refaktorointikierrokset (r8-r14) lyhensivät hitaimpia testejä, kuten mobiiliselaintarkistuksen 164 sekunnista 63 sekuntiin (n=3). Muutimme myös virheiden laskentaa: epäonnistumisten laskeminen työvaiheittain ajojen sijaan osoitti, että 42 punaista ajoa johtuivat usein vain kuudesta perussyystä.

Tämä kokemus vahvisti jatkuvan integraation parhaita käytäntöjä:
1. Mittaa ensin: ota aikaa todellisesta odotuksesta ja laske toimenpiteet ennen ratkaisujen valintaa.
2. Todista jokainen nopeutus laskevalla testillä ja kontrollilla, joka epäonnistuu vanhalla koodilla.
3. Aja kevyet tarkistukset paikallisesti ennen koodin viemistä, jotta päähaara pysyy puhtaana.
4. Pidä tahalliset testivirheet ja kontrollit erillisissä tilapäishaaroissa, älä koskaan masterissa.
5. Käsittele epävakaat testit aitoina vikoina välittömällä prioriteetilla.
6. Refaktoroi jatkuvasti pienissä, mitatuissa erissä ilmoitetuilla otoskoilla.
7. Osoita jokainen rikkoutunut työ yhdelle vastuuhenkilölle heti.

Integraatioputken korjaaminen nopeuttaa suoraan uusien tuoteominaisuuksien toimittamista. Lyhyemmät palautejaksot ja luotettava vihreä koodi takaavat vauhdin ja varmuuden.
