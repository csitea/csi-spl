---
id: 2026-10-09-feature-release-notes
lang: sv
type: news
title: "Utforska versionsanteckningar enkelt"
summary: "Följ de 30 senaste ändringarna och uppdateringarna inuti applikationen med den nya dialogrutan för versionsanteckningar."
date: 2026-10-09
published: 2026-10-09T14:38:00Z
author: a-686
agy_review: a-760
tags: [feature, release-notes]
draft: false
image: 2026-10-09-feature-release-notes.webp
image_alt: "En abstrakt, modern digital ändringslogg och uppdateringsspårare som visar versioner och versionsanteckningar i ett stilrent gränssnitt"
image_prompt: "An abstract, modern digital changelog and update tracker, showing versions and release notes in a clean UI"
---
**Vad det är**

Dialogrutan för versionsanteckningar är en dedikerad ändringslogg. Den extraherar klarspråkliga och tekniska versionsanteckningar från commit-trailers och presenterar dem direkt i arbetsytan.

**Varför använda den**

Den håller alla – från vanliga användare till utvecklare – informerade om vad som har ändrats, hur det ändrades och varför, utan att de behöver leta i git-loggar eller externa system för ändringshantering.

**Hur du använder den**

Klicka på appversionen längst ner i den vänstra panelen (eller i statusfältet på en mobil) och välj 'Versionsanteckningar'. En dialogruta öppnas och visar de 30 senaste ändringarna. Klicka på valfri ändring för att läsa den fullständiga beskrivningen med både vanliga ord och tekniska termer. Du kan använda `j` och `k` för att navigera mellan rader på en dator, eller klicka på 'Läs in äldre versioner' längst ner för att se äldre poster. Varje anteckning kan delas via en stabil `/releases/<ref>`-länk.

**Det gamla sättet**

Ändringar spårades ofta manuellt i externa dokument, eller så fick användare förlita sig på separata tillkännagivanden och rå git-historik för att förstå nya funktioner och fixar. 

**Det nya sättet**

Versionsanteckningar integreras nu automatiskt. Varje giltig ändring hämtas direkt från commit-trailers, vilket säkerställer att ändringsloggen alltid är korrekt och tillgänglig för alla i en lättläst tabellayout precis där de arbetar.
