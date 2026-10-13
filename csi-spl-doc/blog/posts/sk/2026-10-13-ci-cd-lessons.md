---
id: 2026-10-13-ci-cd-lessons
lang: sk
type: news
title: "Čo nás naučili včerajšie problémy s CI/CD"
summary: "Pozastavenie nových funkcií pre opravu CI/CD a refaktorovanie testov skrátilo časy a urýchlilo ďalší vývoj."
date: 2026-10-13
published: 2026-10-13T06:04:11Z
author: a-366
agy_review: a-366
tags: [cicd, refactoring, quality, testing, performance]
image: 2026-10-13-ci-cd-lessons.webp
image_alt: "Futuristické automatizované potrubie nepretržitej integrácie a nasadzovania s robotickými ramenami a zelenými značkami zaškrtnutia."
image_prompt: "a futuristic automated pipeline with robotic arms, circuit boards, glowing tracks, green checkmarks, and digital interface nodes, digital art, no logos"
draft: false
---
12. októbra 2026 náš proces priebežnej integrácie čelil výrazným ťažkostiam. Hlavná vetva bola častejšie červená ako zelená: z 22 dokončených behov kontroly kvality na vetve master bolo 10 zelených a 12 červených, pričom ďalších 36 behov bolo zrušených, pretože ich nahradili novšie odoslania. Získanie spätnej väzby trvalo 47 až 61 minút na každé odoslanie a nasadzovanie webového rozhrania v prostrediach dev a prd sa zastavilo približne na dve hodiny. Podstatné je, že väčšinu červených behov spôsobili nestabilné testy a súbehy procesov, nie skutočné chyby v produkte.

Keď sa hlavná vetva pokazí, trpí každá aktívna línia vo flotile. Odosielanie zmien do červenej vetvy mätie vývojárov a znásobuje zlyhania. Vlastník projektu rozhodol pozastaviť vývoj nových funkcií a predbežné refaktorovanie, kým nebude integrácia stabilná a rýchla. Znamenalo to prijať pomalšie dopoludnie výmenou za podstatne rýchlejšie a spoľahlivejšie dni v budúcnosti.

Zamerali sme sa na skutočné prekážky. Po prvé, presun testovacích úloh na hostované servery GitHub skrátil celkový čas behu z približne 50 minút na medián 30.4 minúty (n=12), čím sa prakticky odstránilo čakanie v rade z 19 minút na menej ako 0.1 minúty. Po druhé, brána kvality bola upravená tak, aby testovala iba časti dotknuté odoslaním, pričom vychádza z posledného zeleného behu každej úlohy namiesto slepého opakovania celého systému. Po tretie, rýchle lokálne kontroly pred odoslaním zachytili jednoduché chyby v priebehu niekoľkých sekúnd. Po výmene serverov nasledovali cielené kolá refaktorovania (od r8 po r14), ktoré ubrali minúty z najpomalších testov, napríklad skrátením testu mobilného prehliadača zo 164 na 63 sekúnd (n=3). Zmenili sme aj pohľad na chyby: počítanie zlyhaní podľa úloh a nie podľa behov ukázalo, že 42 červených behov často pramenilo len zo šiestich hlavných príčin.

Táto skúsenosť upevnila kľúčové osvedčené postupy priebežnej integrácie:
1. Najprv merajte: zaznamenajte skutočné čakanie a spočítajte operácie pred navrhovaním riešení.
2. Dokážte každé zrýchlenie počítacím testom a kontrolou, ktorá zlyhá pri starom správaní.
3. Spúšťajte nenáročné kontroly lokálne pred odoslaním kódu, aby hlavná vetva zostala čistá.
4. Zámerné zlyhania testov a kontroly uchovávajte v dočasných vetvách, nikdy nie v masteri.
5. Pristupujte k nestabilným testom ako k reálnym chybám s okamžitou prioritou.
6. Refaktorujte priebežne v malých, meraných kolách s presne stanovenou vzorkou.
7. Každú neúspešnú úlohu okamžite priraďte jedinému riešiteľovi.

Oprava priebežnej integrácie priamo zrýchľuje dodávanie budúcich funkcií. Kratšie cykly spätnej väzby a spoľahlivá zelená vetva prinášajú rýchlosť a istotu.
