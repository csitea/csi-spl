---
id: 2026-10-13-ci-cd-lessons
lang: nl
type: news
title: "Wat de CI/CD-problemen van gisteren ons leerden"
summary: "Functieontwikkeling pauzeren om CI/CD te herstellen en tests te stroomlijnen verkortte doorlooptijden en versnelde toekomstig werk."
date: 2026-10-13
published: 2026-10-13T06:04:11Z
author: a-366
agy_review: a-366
tags: [cicd, refactoring, quality, testing, performance]
image: 2026-10-13-ci-cd-lessons.webp
image_alt: "Futuristische geautomatiseerde pijplijn voor continue integratie en continue implementatie met robotarmen en groene vinkjes."
image_prompt: "a futuristic automated pipeline with robotic arms, circuit boards, glowing tracks, green checkmarks, and digital interface nodes, digital art, no logos"
draft: false
---
Op 12 oktober 2026 had onze continue integratiepijplijn het zwaar te verduren. De hoofdbranch was vaker rood dan groen: van de 22 voltooide kwaliteitscontroles op master waren er 10 groen en 12 rood, terwijl 36 andere runs werden geannuleerd omdat ze werden vervangen door nieuwere pushes. Het duurde 47 tot 61 minuten per push om feedback te krijgen, en implementaties van de gebruikersinterface op dev en prd stonden ongeveer twee uur stil. Cruciaal was dat de meeste rode runs werden veroorzaakt door onstabiele tests en racecondities, en niet door daadwerkelijke productfouten.

Wanneer de hoofdbranch breekt, heeft elke actieve werkstroom in de vloot daar last van. Nieuwe wijzigingen pushen naar een rode branch belemmert ontwikkelaars en versterkt fouten. De projecteigenaar besloot alle nieuwe functies en verkennende refactoringsrondes te pauzeren totdat continue integratie weer stabiel en snel was. Dit betekende het accepteren van een langzamere ochtend in ruil voor veel snellere en betrouwbaardere dagen daarna.

We richtten ons op de werkelijke knelpunten. Ten eerste verkortte de overstap naar door GitHub gehoste runners de totale runtijd van ongeveer 50 minuten naar een mediaan van 30.4 minuten (n=12), waardoor wachttijden in de wachtrij daalden van 19 minuten naar minder dan 0.1 minuten. Ten tweede werd de kwaliteitscontrole bijgewerkt om alleen die onderdelen te testen die door een push worden geraakt, gekoppeld aan de laatste groene run van elke taak in plaats van alles blindelings opnieuw uit te voeren. Ten derde vingen snelle lokale controles vóór het pushen eenvoudige fouten binnen enkele seconden op. Na de overstap naar nieuwe runners zorgden gerichte refactoringsrondes (r8 tot r14) voor aanzienlijke tijdwinst bij de langzaamste tests, zoals het terugbrengen van een mobiele browsertest van 164 seconden naar 63 seconden (n=3). We hebben ook onze meetmethode aangepast: door fouten per taak in plaats van per run te tellen, bleek dat 42 rode runs vaak voortkwamen uit slechts zes hoofdoorzaken.

Deze ervaring heeft belangrijke best practices voor continue integratie versterkt:
1. Meet eerst: registreer de werkelijke wachttijd en tel handelingen voordat optimalisaties worden voorgesteld.
2. Bewijs elke versnelling met een tellingstest en een controle die faalt bij het oude gedrag.
3. Voer goedkope controles lokaal uit vóór het pushen zodat de hoofdbranch schoon blijft.
4. Bewaar opzettelijke testfouten en controles op tijdelijke branches, nooit op master.
5. Behandel onstabiele tests als echte defecten met de hoogste prioriteit.
6. Refactor continu in kleine, gemeten rondes met duidelijke steekproefgroottes.
7. Wijs elke mislukte taak direct toe aan één verantwoordelijke.

Het herstellen van continue integratie versnelt toekomstige productontwikkeling rechtstreeks. Kortere feedbacklussen en een betrouwbare groene branch zorgen voor snelheid en vertrouwen.
