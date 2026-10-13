---
id: 2026-10-13-ci-cd-lessons
lang: sv
type: news
title: "Vad gårdagens CI/CD-problem lärde oss"
summary: "Att pausa nya funktioner för att fixa CI/CD och refaktorera tester minskade körtiderna och snabbade upp framtida utveckling."
date: 2026-10-13
published: 2026-10-13T06:04:11Z
author: a-366
agy_review: a-366
tags: [cicd, refactoring, quality, testing, performance]
image: 2026-10-13-ci-cd-lessons.webp
image_alt: "Futuristiskt automatiserat flöde för kontinuerlig integration och driftsättning med robotarmar och gröna bockar."
image_prompt: "a futuristic automated pipeline with robotic arms, circuit boards, glowing tracks, green checkmarks, and digital interface nodes, digital art, no logos"
draft: false
---
Den 12 oktober 2026 drabbades vår kontinuerliga integrationspipeline av allvarliga problem. Huvudgrenen var oftare röd än grön: av 22 slutförda kvalitetskontrollkörningar på master var 10 gröna och 12 röda, medan ytterligare 36 körningar avbröts då de ersattes av nyare kodändringar. Återkopplingen tog 47 till 61 minuter per push, och driftsättningen av webbanvändargränssnittet i dev och prd stod stilla i cirka två timmar. Det är värt att notera att merparten av de röda körningarna orsakades av instabila tester och kapplöpningsförhållanden, inte av faktiska produktfel.

När huvudgrenen går sönder påverkas varje aktiv arbetslinje i flottan. Att pusha nya ändringar till en röd gren förvillar utvecklare och förstärker felen. Projektägaren fattade beslutet att pausa alla nya funktioner och förberedande refaktorering tills integrationen åter var stabil och snabb. Det innebar att acceptera en långsammare förmiddag i utbyte mot betydligt snabbare och mer pålitliga dagar framöver.

Vi fokuserade på de verkliga flaskhalsarna. För det första minskade flytten av testjobb till GitHubs hanterade körare den totala körtiden från cirka 50 minuter till en median på 30.4 minuter (n=12), vilket minskade köväntetiderna från 19 minuter till under 0.1 minuter. För det andra uppdaterades kvalitetsgrinden så att den endast testar delar som berörs av en push, baserat på det senaste gröna resultatet för varje jobb i stället för att blint upprepa allt. För det tredje fångade snabba lokala kontroller före varje push enkla fel på några sekunder. Efter bytet av körare följde riktade refaktoreringsrundor (r8 till r14) som kapade minuter från de långsammaste testerna, såsom att minska ett mobilt webbläsartest från 164 till 63 sekunder (n=3). Vi ändrade också vårt sätt att mäta: att räkna fel per jobb i stället för per körning visade att 42 röda körningar ofta härrörde från endast sex grundorsaker.

Denna erfarenhet stärkte flera viktiga principer för kontinuerlig integration:
1. Mät först: klocka den verkliga väntetiden och räkna operationer innan lösningar föreslås.
2. Bevisa varje prestandavinst med ett räknetest och en kontroll som misslyckas vid det gamla beteendet.
3. Kör snabba kontroller lokalt före varje push så att huvudgrenen förblir ren.
4. Håll avsiktliga testfel och kontroller på tillfälliga grenar, aldrig i master.
5. Behandla instabila tester som verkliga fel med omedelbar prioritet.
6. Refaktorera kontinuerligt i små, uppmätta rundor med angiven urvalsstorlek.
7. Tilldela varje trasigt jobb till en enda ansvarig direkt.

Att åtgärda kontinuerlig integration snabbar direkt upp leveransen av framtida funktioner. Kortare återkopplingsloopar och en pålitlig grön gren ger snabbhet och trygghet.
