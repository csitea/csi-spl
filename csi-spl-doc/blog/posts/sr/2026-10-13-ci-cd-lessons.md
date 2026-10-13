---
id: 2026-10-13-ci-cd-lessons
lang: sr
type: news
title: "Šta su nas naučili jučerašnji problemi sa CI/CD"
summary: "Pauziranje novih funkcija radi popravke CI/CD i optimizacije testova skratilo je vreme izvršavanja i ubrzalo budući razvoj."
date: 2026-10-13
published: 2026-10-13T06:04:11Z
author: a-366
agy_review: a-366
tags: [cicd, refactoring, quality, testing, performance]
image: 2026-10-13-ci-cd-lessons.webp
image_alt: "Futuristički automatizovani cevovod za kontinualnu integraciju i isporuku sa robotskim rukama i zelenim kvačicama."
image_prompt: "a futuristic automated pipeline with robotic arms, circuit boards, glowing tracks, green checkmarks, and digital interface nodes, digital art, no logos"
draft: false
---
Dana 12. oktobra 2026. godine, naš proces kontinualne integracije naišao je na ozbiljne poteškoće. Glavna grana bila je češće crvena nego zelena: od 22 završena izvršavanja kontrole kvaliteta na master grani, 10 je bilo zeleno a 12 crveno, dok je još 36 izvršavanja otkazano jer su ih zamenile novije izmene. Povratna informacija trajala je od 47 do 61 minuta po slanju koda, a primena veb interfejsa na dev i prd okruženjima stajala je oko dva sata. Važno je naglasiti da je većina neuspelih izvršavanja bila uzrokovana nestabilnim testovima i preklapanjem procesa, a ne stvarnim greškama u proizvodu.

Kada se glavna grana pokvari, svaka aktivna linija rada u floti trpi posledice. Slanje novih izmena na crvenu granu zbunjuje programere i umnožava greške. Vlasnik projekta doneo je odluku da zaustavi razvoj novih funkcionalnosti i preliminarno refaktorisanje sve dok integracija ne postane stabilna i brza. To je značilo prihvatanje sporijeg prepodneva u zamenu za znatno brže i pouzdanije dane koji slede.

Fokusirali smo se na stvarna uska grla. Prvo, prelazak na izvršioce hostovane na platformi GitHub smanjio je ukupno vreme izvršavanja sa oko 50 minuta na medijanu od 30.4 minuta (n=12), praktično eliminišući čekanje u redu sa 19 minuta na manje od 0.1 minuta. Drugo, kapija kvaliteta je ažurirana tako da proverava samo one delove koje dato slanje menja, oslanjajući se na poslednje uspešno izvršavanje svakog posla umesto slepog ponavljanja svega. Treće, brze lokalne provere pre slanja otkrile su jednostavne propuste za nekoliko sekundi. Nakon promene izvršilaca usledile su ciljane runde refaktorisanja (od r8 do r14) koje su uštedele minute na najsporijim testovima, kao što je skraćivanje testa mobilnog pregledača sa 164 na 63 sekunde (n=3). Takođe smo promenili pristup merenju: brojanje grešaka po zadacima, a ne po ukupnim pokretanjima, otkrilo je da su 42 neuspela pokretanja često proisticala iz samo šest osnovnih uzroka.

Ovo iskustvo utvrdilo je ključne dobre prakse kontinualne integracije:
1. Prvo izmerite: zabeležite stvarno čekanje i izbrojte operacije pre predlaganja rešenja.
2. Dokažite svako ubrzanje testom brojanja i kontrolom koja pada pri starom ponašanju.
3. Pokrećite brze provere lokalno pre slanja kako bi glavna grana ostala čista.
4. Namerna obaranja testova i kontrole držite na privremenim granama, nikada na master grani.
5. Tretirajte nestabilne testove kao stvarne nedostatke najvišeg prioriteta.
6. Refaktorišite neprekidno u malim, merenim rundama sa jasno navedenim uzorkom.
7. Dodelite svaki neuspeli zadatak odmah jednom odgovornom izvršiocu.

Sređivanje kontinualne integracije direktno ubrzava isporuku budućih funkcionalnosti. Kraći ciklus povratnih informacija i pouzdana zelena grana donose brzinu i samopouzdanje.
