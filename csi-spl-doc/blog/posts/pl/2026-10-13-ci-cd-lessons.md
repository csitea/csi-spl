---
id: 2026-10-13-ci-cd-lessons
lang: pl
type: news
title: "Czego nauczyły nas wczorajsze problemy z CI/CD"
summary: "Wstrzymanie prac nad funkcjami w celu naprawy CI/CD i refaktoryzacji testów skróciło czasy wykonania i przyspieszyło przyszły rozwój."
date: 2026-10-13
published: 2026-10-13T06:04:11Z
author: a-366
agy_review: a-366
tags: [cicd, refactoring, quality, testing, performance]
image: 2026-10-13-ci-cd-lessons.webp
image_alt: "Futurystyczny zautomatyzowany potok ciągłej integracji i wdrażania z ramionami robotycznymi i zielonymi znacznikami."
image_prompt: "a futuristic automated pipeline with robotic arms, circuit boards, glowing tracks, green checkmarks, and digital interface nodes, digital art, no logos"
draft: false
---
12 października 2026 roku nasz potok ciągłej integracji napotkał poważne trudności. Główna gałąź była częściej czerwona niż zielona: na 22 ukończone przebiegi bramki jakości na gałęzi master, 10 było zielonych, a 12 czerwonych, podczas gdy kolejne 36 przebiegów zostało anulowanych jako zastąpione przez nowsze commity. Oczekiwanie na informację zwrotną trwało od 47 do 61 minut na commit, a wdrażanie interfejsu sieciowego w środowiskach dev i prd zatrzymało się na około dwie godziny. Co istotne, większość czerwonych przebiegów wynikała z niestabilnych testów i wyścigów procesów, a nie z rzeczywistych błędów produktu.

Gdy główna gałąź ulega awarii, cierpi każda aktywna linia prac we flocie. Wprowadzanie nowych zmian na czerwoną gałąź dezorientuje programistów i potęguje awarie. Właściciel projektu podjął decyzję o wstrzymaniu prac nad nowymi funkcjami i refaktoryzacji wstępnej, dopóki integracja nie stanie się stabilna i szybka. Oznaczało to zaakceptowanie wolniejszego poranka w zamian za znacznie szybsze i bardziej niezawodne dni w przyszłości.

Skupiliśmy się na rzeczywistych wąskich gardłach. Po pierwsze, przeniesienie zadań testowych na hostowane maszyny GitHub skróciło pełny czas wykonywania z około 50 minut do mediany 30.4 minuty (n=12), praktycznie eliminując oczekiwanie w kolejce z 19 minut do poniżej 0.1 minuty. Po drugie, bramka jakości została zaktualizowana tak, aby uruchamiać testy tylko dla części zmienionych w danym commicie, bazując na ostatnim zielonym przebiegu każdego zadania, zamiast ślepo ponawiać całość. Po trzecie, tanie lokalne kontrole przed wysłaniem wychwytywały proste błędy w kilka sekund. Po zmianie maszyn nastąpiły ukierunkowane rundy refaktoryzacji (od r8 do r14), które skróciły czas najwolniejszych testów, np. zmniejszając czas testu przeglądarki mobilnej ze 164 do 63 sekund (n=3). Zmieniliśmy również sposób analizy: zliczanie błędów według zadań, a nie przebiegów, ujawniło, że 42 nieudane przebiegi wynikały zaledwie z sześciu przyczyn źródłowych.

To doświadczenie umocniło kluczowe dobre praktyki ciągłej integracji:
1. Najpierw mierz: zmierz rzeczywisty czas oczekiwania i policz operacje przed zaproponowaniem zmian.
2. Udowodnij każde przyspieszenie testem zliczającym i kontrolą, która kończy się błędem w starym zachowaniu.
3. Wykonuj szybkie kontrole lokalnie przed wysłaniem, aby główna gałąź pozostała czysta.
4. Celowe błędy testowe i kontrole umieszczaj na gałęziach tymczasowych, nigdy na masterze.
5. Traktuj niestabilne testy jako faktyczne usterki o najwyższym priorytecie.
6. Refaktoryzuj w sposób ciągły w małych, mierzonych rundach o określonej wielkości próby.
7. Natychmiast przypisuj każde przerwane zadanie jednemu odpowiedzialnemu wykonawcy.

Naprawa ciągłej integracji bezpośrednio przyspiesza dostarczanie przyszłych funkcji. Krótszy czas uzyskiwania informacji zwrotnej i stabilna zielona gałąź zapewniają tempo i pewność działania.
