---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: fi
type: news
title: "Huono yrittäjä, hyvä veroanalyytikko: yksityinen Spool-Hub-työtila hoiti yritykseni verot"
summary: "En pysy yritykseni veroasioiden perässä. Yksityinen Spool-Hub-työtila ja yksi agentti järjestivät Vero.fi:n vuoden asiakirjat noin kolmessa tunnissa."
share_text: "Myönnän: olen huono pitämään kirjaa yritykseni veroista. Yksi agentti, oma pöytäkoneeni ja Vero.fi – ja vuoden asiakirjat olivat järjestyksessä noin kolmessa tunnissa."
share_long: "Huono yrittäjä, hyvä veroanalyytikko.\n\n😅 En ole koskaan pysynyt yritykseni veroasioiden perässä, vaikka olen yrittänyt monta kertaa.\n🖥️ Agentti toimii omalla pöytäkoneellani, ja ohjaan sitä Spool-Hubin selainkäyttöliittymästä.\n🔐 Kirjaudun Vero.fi:hin itse; agentti ei koskaan näe tunnuksiani.\n📂 Agentti haki vuoden päätökset ja kirjeet, järjesti ne kuukausittain ja kirjoitti perustellun sähköpostin kirjanpitäjälle.\n⏱️ Käsin työ vei 5–7 tuntia. Käytin noin 3 tuntia automaation ja käyttöönoton rakentamiseen; tästä eteenpäin sen pitäisi viedä alle 15 minuuttia viikossa.\n💡 Kun näin kaiken yhdessä paikassa, aloin epäillä maksavani liikaa veroja.\n\nLue koko kirjoitus:"
date: 2026-11-25
published: 2026-11-25T13:55:48Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Infografiikka: yrittäjä ja veropaperipinoja, robotti veroanalyytikkona, keskellä yksityinen Spool-Hub-työtila, agentti avaa Vero.fi:n selaimessa MCP:n kautta, asiakirjat pilvilevyllä vuosi-, vero- ja maksukansioissa, sähköposti kirjanpitäjälle ja ajat: käsin 5–7 tuntia, käyttöönotto ja automaatio 3 tuntia, seuraavalla kerralla 15 minuuttia."
image_prompt: "the owner's own infographic (made with Gemini), published as-is; centre-cropped to 16:9 by the blog encoder"
---
Myönnän sen heti: olen huono yrittäjä. En pysy yritykseni veroasioiden perässä. Olen monta kertaa yrittänyt olla kurinalainen ja automatisoida asian, mutta se ei ole koskaan toteutunut.

Tällä kertaa sain kaiken yhteen paikkaan, ja se pani minut ajattelemaan: maksan luultavasti yritykseni veroja liikaa. Samaan aiheeseen liittyy LinkedIn-kirjoitus [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

Seuraavaksi automaatio – skriptejä sekä Spool-Hubin ajastusta ja infraa –, jotta viikkotarkistus toimii itsestään. Skriptit ovat julkisia: [github.com/csitea/csi-tax](https://github.com/csitea/csi-tax).

## 1. 🖥️ Agentti omalla koneella, ohjaus selaimesta

Agentin voi asentaa omalle kannettavalle tai pöytäkoneelle. Kun se on rekisteröity Spool-Hubin selainkäyttöliittymään, ohjaan sitä sieltä. Agentti voi käyttää MCP:tä ja Firefoxia (tai mitä tahansa MCP-selainta) ja hakea tietoa mistä tahansa järjestelmästä, johon minulla on pääsy. Tässä se oli Verohallinnon asiointipalvelu Vero.fi (vero = tax).

## 2. 📂 Mitä tapahtui

Yritykseni yksityisessä työtilassa kysyin ensin, miten ennakkovero lasketaan. Pyysin sitten agenttia avaamaan selainikkunan pöytäkoneelleni.

- Kirjauduin itse. Agentti ei kirjoita, lue eikä tallenna tunnuksiani.
- Agentti haki vuoden päätökset, kirjeet ja maksutiedot, järjesti ne pilvilevylle kuukausittain ja tyypeittäin ja järjesti samalla tavalla aiemmat veroasiakirjat.
- Pyysin tiketin jokaisesta tarkistettavasta aiheesta, ja agentit kirjoittivat perustellun sähköpostin kirjanpitäjälle.
- Ohjasin kaikkea lyhyillä viesteillä keskustelussa. Asiakirjat pysyivät yksityisinä, eivät avoimen lähdekoodin projektissa.

## 3. ⏱️ Ennen ja jälkeen

Käsin työ vei 5–7 tuntia.

Nyt kirjoitin 96 lyhyttä viestiä ja kirjauduin noin kuusi kertaa. Noin 3 tuntia meni automaation ja käyttöönoton rakentamiseen (UTC, 24.11.2026):

| vaihe | aika |
|---|---|
| ensimmäinen kysymys | 14.23 |
| pyyntö agentille, kirjautuminen | 14.59–15.12 |
| oma koodivarasto ja asiakirjojen haku | 15.56–17.22 |
| 30/32 asiakirjaa pilvilevyllä | 17.45 |
| sähköposti valmis | 18.10 |

Tästä eteenpäin saman veroajon pitäisi viedä alle 15 minuuttia viikossa.

## 4. 📅 Viikkoraportti

Pyysin viikoittaista raporttia uusista asiakirjoista, eräpäivistä ja avoimista kysymyksistä. Koodi on valmis, mutta ajastusta ei ole vielä otettu käyttöön.

## 5. 🏢 Csitea Oy

Csitea Oy on konsulttiyritys, joka rahoittaa ja kehittää Spool-Hubia. Se tarjoaa pilvi- ja DevOps-konsultointia (AWS, Google Cloud, Kubernetes, Terraform, Python-taustajärjestelmät) ja verkkokauppapalvelua: [csitea.net](https://csitea.net).

## 6. 🔧 Tekninen osa: palvelutili

Pilvilevyllä agentti toimii yrityksen varmuuskopioinnin palvelutilinä, ei minun tunnuksillani. Palvelutili näkee vain kansiot, jotka on jaettu sille. Veroasiakirjoille annoin sille yhden juurikansion, kaikkien talousasiakirjojen kansion, ja agentti loi sen alle rakenteen vuosi/kuukausi/vero/tyyppi. Tilin avain on koneella, ei gitissä; koodi lukee avaimen ja kansion nimetyistä muuttujista.

## 7. 🏭 Avointa lähdekoodia

Spool Hub on avointa lähdekoodia (GNU AGPL v3). Lue ja lataa koodi ja aja oma instanssisi pilvessä tai `docker compose` -komennolla: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Haluatko oman demotilin? Ota yhteyttä: [csitea.net](https://csitea.net).
