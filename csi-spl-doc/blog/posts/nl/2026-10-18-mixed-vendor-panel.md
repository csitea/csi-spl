---
id: 2026-10-18-mixed-vendor-panel
lang: nl
type: news
title: "Vraag het meer dan één brein: waarom onze AI-agents in panels van verschillende leveranciers zitten"
summary: "Modellen van verschillende leveranciers leren van andere data en feedback, dus ze missen andere dingen. Een panel van hen ziet meer dan één model alleen."
date: 2026-10-18
published: 2026-10-19T10:22:49Z
author: c-414
agy_review: a-360
tags: [agents, panel, vendors, consensus, open-source]
image: 2026-10-18-mixed-vendor-panel.webp
image_alt: "Vijf verschillende cartoonrobots zitten rond een tafel en discussiëren over een plan."
image_prompt: "a funny cartoon of five very different robots sitting round a table discussing a plan: an orange boxy one, a blue round one, a green long-neck one, a purple one on treads, a yellow teapot-shaped drone; one points at the plan, one scratches its head, one objects, one nods, one sips oil; bright flat-colour cartoon; robots only, no logos, no lettering, no text"
draft: false
---
Eén slim model dat het met zichzelf eens is, is geen tweede mening.

## 🧠 Hoe een model leert

Een groot taalmodel wordt in twee grote stappen getraind. Eerst komt de pre-training: het leest een enorme hoeveelheid tekst en leert het volgende woord te voorspellen, en daaruit pikt het taal, feiten en redeneerpatronen op. Daarna komt de fine-tuning: mensen en automatische controles beoordelen zijn antwoorden, en het wordt bijgestuurd richting de behulpzame antwoorden (met feedbackmethoden zoals RLHF) en richting de eigen regels van de leverancier over hoe het zich hoort te gedragen.

## 🔀 Waarom de modellen niet hetzelfde zijn

De modellen van verschillende leveranciers hebben veel gemeen. Een groot deel van het openbare web, boeken en code zit in al hun trainingsdata, en het basisrecept lijkt op elkaar. Maar elke leverancier kiest een eigen datamix, een eigen afkapdatum, eigen trainingskeuzes en eigen feedback en regels. Daardoor heeft elk model zijn eigen sterke punten, en zijn eigen blinde vlekken.

Daar draait het om. Als twee modellen uit dezelfde familie het eens zijn, delen ze misschien gewoon dezelfde blinde vlek. Als modellen van verschillende leveranciers, anders getraind, elk op eigen kracht tot hetzelfde antwoord komen, dan is die overeenstemming sterker bewijs.

## 🤖 Hoe een panel werkt in spool-hub

spool-hub draait een vloot AI-agents van meerdere leveranciers: Claude, Grok, Antigravity en Mistral. Elk soort taak heeft een hoofdleverancier en een reserve, en de reserve neemt het over na twee mislukte pogingen.

Groter werk, zoals een ronde refactoring of bugfixes, begint met een panel:

1. Een redacteur schrijft een plan: wat er moet gebeuren, waarom, en hoe je bewijst dat het gelukt is.
2. Panelleden van andere leveranciers lezen het plan, brengen hun bezwaren in en stellen wijzigingen voor.
3. De redacteur verwerkt de bezwaren. Elk panellid ondertekent het plan, en de afgesproken versie wordt v1.0: de consensus.
4. Daarna werken bouwlanes rij voor rij naar dat ene afgesproken doel toe.
5. Elke rij wordt, voordat hij landt, gecontroleerd door een reviewer van een andere leverancier dan die van de auteur.

De agents zijn het weleens oneens, en dat is welkom: onenigheid over het plan kost weinig, een fout die pas na de bouw wordt gevonden kost veel. Zodra ze het eens zijn, trekt iedereen aan hetzelfde zeel.

## ✨ Verschillende blikken, één doel

Een gemengd panel is als een goed team van mensen: verschillende achtergronden, verschillende instincten, één gedeeld plan. Het houdt het werk ook gaande als één leverancier uitvalt, want een ander kan inspringen.

---

spool-hub is open source: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Iedereen kan het installeren met de hulp van AI-agents, dankzij de actuele documentatie en het eigen documentformaat, Qto.

beheerd door [Csitea Oy AB](https://csitea.net)
