---
id: 2026-10-09-feature-release-notes
lang: fi
type: news
title: "Tutki julkaisutietoja helposti"
summary: "Seuraa sovelluksen 30 viimeisintä muutosta ja päivitystä uuden Julkaisutiedot-valintaikkunan avulla."
date: 2026-10-09
published: 2026-10-09T14:38:00Z
author: a-686
agy_review: a-760
tags: [feature, release-notes]
draft: false
image: 2026-10-09-feature-release-notes.webp
image_alt: "Abstrakti, moderni digitaalinen muutosloki ja päivitysten seurantatyökalu, joka näyttää versiot ja julkaisutiedot selkeässä käyttöliittymässä"
image_prompt: "An abstract, modern digital changelog and update tracker, showing versions and release notes in a clean UI"
---
**Mikä se on**

Julkaisutiedot-valintaikkuna on omistettu muutoslokin seurantatyökalu. Se poimii yleiskieliset ja tekniset julkaisutiedot commit-viestien trailereista ja esittää ne suoraan työtilassa.

**Miksi käyttää sitä**

Se pitää kaikki – tavallisista käyttäjistä insinööreihin – ajan tasalla siitä, mikä muuttui, miten se muuttui ja miksi, ilman että tarvitsee kaivella git-lokeja tai ulkoisia muutosten seurantatyökaluja.

**Kuinka käyttää sitä**

Napsauta sovelluksen versiota vasemman ruudun alaosassa (tai puhelimen tilarivillä) ja valitse 'Release notes' (Julkaisutiedot). Valintaikkuna avautuu ja näyttää 30 tuoreinta muutosta. Napsauttamalla mitä tahansa muutosta voit lukea sen täyden kuvauksen sekä yleiskielellä että teknisin termein. Voit käyttää `j` ja `k` näppäimiä navigoidaksesi rivejä työpöydällä, tai napsauttaa 'Load older versions' (Lataa vanhempia versioita) alaosassa nähdäksesi vanhempia merkintöjä. Jokainen huomautus voidaan jakaa pysyvän `/releases/<ref>` -linkin kautta.

**Vanha tapa**

Muutoksia seurattiin usein manuaalisesti ulkoisissa asiakirjoissa, tai käyttäjien piti luottaa erillisiin ilmoituksiin ja raakoihin git-historioihin ymmärtääkseen uusia ominaisuuksia ja korjauksia. 

**Uusi tapa**

Julkaisutiedot on nyt integroitu automaattisesti. Jokainen kelvollinen muutos tuodaan suoraan commit-viestien trailereista, mikä varmistaa, että muutosloki on aina tarkka ja kaikkien saatavilla luettavassa taulukkomuodossa juuri siellä missä he työskentelevät.
