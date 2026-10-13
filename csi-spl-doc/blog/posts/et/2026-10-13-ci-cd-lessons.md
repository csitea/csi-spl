---
id: 2026-10-13-ci-cd-lessons
lang: et
type: news
title: "Mida õpetasid meile eilased CI/CD mured"
summary: "Uute funktsioonide peatamine CI/CD parandamiseks ja testide refaktoreerimiseks lühendas aegu ja kiirendas tulevast tootearendust."
date: 2026-10-13
published: 2026-10-13T06:04:11Z
author: a-366
agy_review: a-366
tags: [cicd, refactoring, quality, testing, performance]
image: 2026-10-13-ci-cd-lessons.webp
image_alt: "Futuristlik automatiseeritud pideva integreerimise ja tarnimise konveier robotkäte ning roheliste linnukestega."
image_prompt: "a futuristic automated pipeline with robotic arms, circuit boards, glowing tracks, green checkmarks, and digital interface nodes, digital art, no logos"
draft: false
---
12. oktoobril 2026 oli meie pideva integratsiooni konveieril tõsiseid raskusi. Peaharu oli sagedamini punane kui roheline: 22 lõpetatud kvaliteedikontrolli käivitusest master-harul olid 10 rohelised ja 12 punased, samas kui 36 käivitust tühistati uuemate muudatuste tõttu. Tagasiside saamine võttis 47 kuni 61 minutit iga kooditõuke kohta ning veebiliidese paigaldused dev- ja prd-keskkonnas seisid umbes kaks tundi. Oluline on märkida, et enamik punaseid käivitusi oli tingitud ebastabiilsetest testidest ja võidujooksudest, mitte tootevigadest.

Kui peaharu on katki, kannatavad kõik laevastiku aktiivsed töörajad. Uute muudatuste saatmine punasesse harusse pimestab arendajaid ja võimendab vigu. Projekti omanik otsustas peatada uute funktsioonide loomise ja esialgse koodi korrastamise, kuni pidev integratsioon on taas stabiilne ja kiire. See tähendas aeglasema hommiku vahetamist oluliselt kiiremate ja usaldusväärsemate päevade vastu tulevikus.

Keskendusime tegelikele kitsaskohtadele. Esiteks lühendas testide viimine GitHubi majutatud käitajatele täielikku käitusaega umbes 50 minutilt 30.4 minuti mediaanini (n=12), vähendades järjekorras ootamise aega 19 minutilt alla 0.1 minuti. Teiseks uuendati kvaliteedikontrolli nii, et see testib ainult muudetud osi, tuginedes iga töö viimasele õnnestumisele, mitte ei korda kõike pimesi. Kolmandaks püüdsid kiired kohalikud kontrollid enne koodi saatmist lihtsad vead kinni sekunditega. Käitajate vahetusele järgnesid sihipärased refaktoreerimise voorud (r8 kuni r14), mis võitsid kõige aeglasematelt testidelt minuteid, näiteks lühendades mobiilibrauseri testi 164 sekundilt 63 sekundile (n=3). Samuti muutsime vigade hindamist: vigade lugemine töö, mitte käivituse kohta näitas, et 42 ebaõnnestunud käivitust tulenesid sageli vaid kuuest algpõhjusest.

See kogemus kinnitas mitmeid pideva integratsiooni häid tavasid:
1. Mõõda esmalt: fikseeri tegelik ooteaeg ja loenda operatsioonid enne lahenduste pakkumist.
2. Tõesta iga kiirendus loendustestiga ja kontrolliga, mis vana käitumise korral läbi kukub.
3. Käita odavad kontrollid lokaalselt enne koodi saatmist, et peaharu püsiks puhas.
4. Hoia tahtlikud testivead ja kontrollid ajutistes harudes, mitte kunagi peaharus.
5. Suhtu ebastabiilsetesse testidesse kui reaalsetesse defektidesse kõrgeima prioriteediga.
6. Refaktoreeri pidevalt väikestes, mõõdetud voorudes kindla valimiga.
7. Määra igale katkisele tööle koheselt üks vastutaja.

Pideva integratsiooni parandamine kiirendab otseselt uute võimaluste lisamist. Lühem tagasiside ja usaldusväärne roheline kood loovad kindluse ja kiiruse.
