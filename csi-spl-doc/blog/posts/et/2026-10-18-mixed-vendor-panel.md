---
id: 2026-10-18-mixed-vendor-panel
lang: et
type: news
title: "Küsi rohkem kui ühelt mõistuselt: miks meie AI-agendid osalevad eri tarnijate segapaneelides"
summary: "Eri tarnijate mudelid õpivad erinevatest andmetest ja tagasisidest ning neil on erinevad pimetähnid. Mitme mudeli paneel näeb rohkem kui üksinda."
date: 2026-10-18
published: 2026-10-19T10:22:49Z
author: c-414
agy_review: a-360
tags: [agents, panel, vendors, consensus, open-source]
image: 2026-10-18-mixed-vendor-panel.webp
image_alt: "Viis erinevat multikarobotit istuvad ümber laua ja vaidlevad plaani üle."
image_prompt: "a funny cartoon of five very different robots sitting round a table discussing a plan: an orange boxy one, a blue round one, a green long-neck one, a purple one on treads, a yellow teapot-shaped drone; one points at the plan, one scratches its head, one objects, one nods, one sips oil; bright flat-colour cartoon; robots only, no logos, no lettering, no text"
draft: false
---
Üks nutikas mudel, mis iseendaga nõustub, ei ole teine arvamus.

## 🧠 Kuidas mudel õpib

Suuri keelemudeleid treenitakse kahes peamises etapis. Kõigepealt tuleb eeltreening: mudel loeb tohutul hulgal teksti ja õpib ennustama järgmist sõna ning omandab sealt keele, faktid ja arutlusmustrid. Seejärel tuleb peenhäälestus: inimesed ja automaatsed kontrollid hindavad tema vastuseid ning teda häälestatakse kasulike vastuste suunas (tagasisidemeetoditega nagu RLHF) ja oma tarnija reeglite suunas selle kohta, kuidas ta peaks käituma.

## 🔀 Miks mudelid ei ole ühesugused

Eri tarnijate mudelitel on palju ühist. Suur osa avalikust veebist, raamatutest ja koodist on kõigi nende treeningandmetes ning põhiretsept on sarnane. Kuid iga tarnija valib oma andmesegu, oma andmete piirkuupäeva, oma treeningvalikud ning oma tagasiside ja reeglid. Seega on igal mudelil oma tugevused ja oma pimetähnid.

Just selles ongi asi. Kui kaks sama perekonna mudelit on ühel meelel, võib neil lihtsalt olla sama pimetähn. Kui eri tarnijate mudelid, mida on treenitud erinevalt, jõuavad iseseisvalt sama vastuseni, on see üksmeel palju tugevam tõend.

## 🤖 Kuidas paneel spool-hubis töötab

spool-hub juhib mitme tarnija AI-agentide võrgustikku: Claude, Grok, Antigravity ja Mistral. Igal ülesandeliigil on põhitarnija ja varutarnija ning varutarnija võtab töö üle pärast kahte ebaõnnestunud katset.

Suurem töö, näiteks refaktoreerimise või vigade parandamise voor, algab paneeliga:

1. Toimetaja roll koostab plaani: mida teha, miks ja kuidas tõestada, et see töötas.
2. Teiste tarnijate esindajad loevad plaani läbi, esitavad oma vastuväited ja pakuvad välja muudatusi.
3. Toimetaja arvestab vastuväidetega. Iga osapool allkirjastab plaani ja kokkulepitud versioonist saab v1.0: konsensus.
4. Seejärel töötavad arendusrajad selle ühe kokkulepitud eesmärgi nimel, rida realt.
5. Enne koodi liitmist kontrollib iga rida ülevaataja, kes esindab teist tarnijat kui rea autor.

Agendid on eri meelt ja see on teretulnud: lahkarvamus plaani üle on odav, aga pärast ehitamist leitud viga mitte. Kui nad on kokku leppinud, tõmbavad kõik ühes suunas.

## ✨ Erinevad vaated, üks eesmärk

Segapaneel on nagu hea meeskond: erinev taust, erinevad instinktid, üks ühine plaan. Samuti hoiab see töö käigus, kui ühe tarnija teenus katkeb, sest teine saab teatepulga üle võtta.

---

spool-hub on avatud lähtekoodiga: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Igaüks saab selle AI-agentide abiga paigaldada tänu ajakohasele dokumentatsioonile ja selle enda dokumentatsioonivormingule Qto.

teenust haldab [Csitea Oy AB](https://csitea.net)
