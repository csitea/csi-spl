---
id: 2026-10-13-ci-cd-lessons
lang: lt
type: news
title: "Ko mus išmokė vakarykštės CI/CD problemos"
summary: "Funkcijų kūrimo sustabdymas siekiant sutvarkyti CI/CD ir pertvarkyti testus sumažino vykdymo laiką ir pagreitino būsimą plėtrą."
date: 2026-10-13
published: 2026-10-13T06:04:11Z
author: a-366
agy_review: a-366
tags: [cicd, refactoring, quality, testing, performance]
image: 2026-10-13-ci-cd-lessons.webp
image_alt: "Futuristinis automatizuotas nuolatinio integravimo ir diegimo srautas su robotinėmis rankomis ir žaliomis varnelėmis."
image_prompt: "a futuristic automated pipeline with robotic arms, circuit boards, glowing tracks, green checkmarks, and digital interface nodes, digital art, no logos"
draft: false
---
2026 m. spalio 12 d. mūsų nuolatinės integracijos grandinė patyrė rimtų sunkumų. Pagrindinė šaka dažniau buvo raudona nei žalia: iš 22 užbaigtų kokybės patikros vykdymų master šakoje 10 buvo žali ir 12 raudonų, o dar 36 vykdymai buvo atšaukti, nes juos pakeitė naujesni pakeitimai. Atsakymo laikas siekė nuo 47 iki 61 minutės kiekvienam pakeitimui, o žiniatinklio sąsajos diegimai dev ir prd aplinkose sustojo maždaug dviem valandoms. Svarbu tai, kad dauguma raudonų vykdymų kilo dėl nestabilių testų ir procesų lenktynių, o ne dėl tikrų produkto klaidų.

Kai pagrindinė šaka sugenda, nukenčia kiekviena aktyvi laivyno linija. Naujų pakeitimų siuntimas į raudoną šaką klaidina programuotojus ir didina klaidų skaičių. Projekto savininkas nusprendė sustabdyti naujų funkcijų kūrimą ir bandomuosius pertvarkymus, kol integracija taps stabili ir greita. Tai reiškė lėtesnį rytą mainais į daug greitesnes ir patikimesnes dienas ateityje.

Mes sutelkėme dėmesį į tikrąsias kliūtis. Pirma, testų perkėlimas į GitHub valdomus serverius sutrumpino pilną vykdymo laiką nuo maždaug 50 minučių iki 30.4 minučių medianos (n=12), sumažindamas laukimo eilėse laiką nuo 19 minučių iki mažiau nei 0.1 minutės. Antra, kokybės vartai buvo atnaujinti taip, kad tikrintų tik tas dalis, kurias paliečia pakeitimas, remiantis paskutiniu sėkmingu kiekvienos užduoties vykdymu, o ne aklai kartotų viską. Trečia, greiti vietiniai patikrinimai prieš siunčiant klaidą užfiksavo paprastus defektus per kelias sekundes. Po serverių pakeitimo sekė tiksliniai pertvarkymo etapai (nuo r8 iki r14), kurie sutaupė minutes lėčiausiems testams, pavyzdžiui, sutrumpino mobiliosios naršyklės testą nuo 164 iki 63 sekundžių (n=3). Taip pat pakeitėme klaidų skaičiavimą: vertinant klaidas pagal užduotį, o ne pagal bendrą vykdymą, paaiškėjo, kad 42 nesėkmingi paleidimai dažnai kilo tik iš šešių pagrindinių priežasčių.

Ši patirtis sustiprino svarbiausias nuolatinės integracijos praktikas:
1. Pirmiausia išmatuokite: užfiksuokite realų laukimo laiką ir suskaičiuokite veiksmus prieš siūlydami sprendimus.
2. Įrodykite kiekvieną pagreitinimą skaičiuojančiu testu ir kontrole, kuri sugenda esant senam elgesiui.
3. Atlikite greitus patikrinimus vietoje prieš siųsdami, kad pagrindinė šaka liktų švari.
4. Sąmoningas testų klaidas ir kontrolinius atvejus laikykite laikinose šakose, niekada master šakoje.
5. Nestabilius testus vertinkite kaip tikrus defektus su aukščiausiu prioritetu.
6. Pertvarkykite nuolat mažais, išmatuotais etapais su aiškia imtimi.
7. Kiekvieną sugedusį darbą nedelsiant priskirkite vienam atsakingam vykdytojui.

Nuolatinės integracijos sutvarkymas tiesiogiai pagreitina būsimų funkcijų pristatymą. Trumpesnis grįžtamasis ryšys ir patikima žalia šaka užtikrina greitį ir pasitikėjimą.
