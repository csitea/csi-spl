---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: fi
type: news
title: "Huono yrittäjä, hyvä veroanalyytikko: yksityinen Spool-Hub-työtila hoiti yritykseni verot"
summary: "En pysy yritykseni veroasioiden perässä. Yksityinen Spool-Hub-työtila ja yksi agentti järjestivät Vero.fi:n vuoden asiakirjat noin kolmessa tunnissa."
share_text: "Myönnän: olen huono pitämään kirjaa yritykseni veroista. Yksi agentti, oma pöytäkoneeni ja Vero.fi – ja vuoden asiakirjat olivat järjestyksessä noin kolmessa tunnissa."
share_long: "Huono yrittäjä, hyvä veroanalyytikko.\n\n😅 En ole koskaan pysynyt yritykseni veroasioiden perässä, vaikka olen yrittänyt monta kertaa.\n🖥️ Agentti toimii omalla pöytäkoneellani, ja ohjaan sitä Spool-Hubin selainkäyttöliittymästä.\n🔐 Kirjaudun Vero.fi:hin itse; agentti ei koskaan näe tunnuksiani.\n📂 Agentti haki vuoden päätökset ja kirjeet, järjesti ne kuukausittain ja kirjoitti perustellun sähköpostin kirjanpitäjälle.\n⏱️ Käyttöönotto kesti noin kolme tuntia.\n💡 Kun näin kaiken yhdessä paikassa, aloin epäillä maksavani liikaa veroja.\n\nLue koko kirjoitus:"
date: 2026-11-25
published: 2026-11-25T13:55:48Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Pääteikkuna, jossa agentti etsii verotiedostoja yrityksen pilvilevyltä; palvelutilin nimi, polut, tunnisteet ja kansioiden nimet on peitetty mustilla laatikoilla."
image_prompt: "a screenshot of the agent's terminal and its side panel on a desktop, private details covered with solid black boxes, cropped to 16:9; not generated"
---
Myönnän sen heti: olen huono yrittäjä. En pysy yritykseni veroasioiden perässä. Olen monta kertaa yrittänyt olla kurinalainen ja automatisoida asian, mutta se ei ole koskaan pysynyt.

Tällä kertaa sain kaiken yhteen paikkaan, ja se pani minut ajattelemaan: maksan luultavasti yritykseni veroja liikaa. Samaan aiheeseen liittyy LinkedIn-kirjoitus [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

## 1. 🖥️ Agentti omalla koneella, ohjaus selaimesta

Agentin voi asentaa omalle kannettavalle tai pöytäkoneelle. Kun se on rekisteröity Spool-Hubin selainkäyttöliittymään, ohjaan sitä sieltä. Agentti voi käyttää MCP:tä ja Firefoxia (tai mitä tahansa MCP-selainta) ja hakea tietoa mistä tahansa järjestelmästä, johon minulla on pääsy. Tässä se oli Verohallinnon asiointipalvelu Vero.fi (vero = tax).

## 2. 📂 Mitä tapahtui

Yritykseni yksityisessä työtilassa kysyin ensin, miten ennakkovero lasketaan. Pyysin sitten agenttia avaamaan selainikkunan pöytäkoneelleni.

- Kirjauduin itse. Agentti ei kirjoita, lue eikä tallenna tunnuksiani.
- Agentti haki vuoden päätökset, kirjeet ja maksutiedot, järjesti ne pilvilevylle kuukausittain ja tyypeittäin ja järjesti samalla tavalla aiemmat veroasiakirjat.
- Pyysin tiketin jokaisesta tarkistettavasta aiheesta, ja agentit kirjoittivat perustellun sähköpostin kirjanpitäjälle.
- Ohjasin kaikkea lyhyillä viesteillä keskustelussa. Asiakirjat pysyivät yksityisinä, eivät avoimen lähdekoodin projektissa.

## 3. ⏱️ Ennen ja jälkeen

Käsin arvioin työn vievän 5–7 tuntia: noin 30 asiakirjaa ladattuna, nimettynä ja arkistoituna (3–5 min kpl), maksujen ja eräpäivien läpikäynti (1–2 h), vanhojen tiedostojen järjestäminen (1 h) ja sähköposti kirjanpitäjälle (1 h). Arvio on omani, ei mitattu.

Nyt kirjoitin 96 lyhyttä viestiä ja kirjauduin noin kuusi kertaa. Käyttöönotto kesti noin 3 tuntia (UTC, 24.11.2026):

| vaihe | aika |
|---|---|
| ensimmäinen kysymys | 14.23 |
| pyyntö agentille, kirjautuminen | 14.59–15.12 |
| oma koodivarasto ja asiakirjojen haku | 15.56–17.22 |
| 30/32 asiakirjaa pilvilevyllä | 17.45 |
| sähköposti valmis | 18.10 |

Agenttipyynnöstä valmiiseen meni 2 h 46 min, kysymyksestä sähköpostiin 3 h 47 min.

## 4. 📅 Viikkoraportti

Pyysin viikoittaista raporttia uusista asiakirjoista, eräpäivistä ja avoimista kysymyksistä. Koodi on valmis, mutta ajastusta ei ole vielä otettu käyttöön.

## 5. 🏢 Csitea Oy

Csitea Oy on konsulttiyritys, joka rahoittaa ja kehittää Spool-Hubia. Se tarjoaa pilvi- ja DevOps-konsultointia (AWS, Google Cloud, Kubernetes, Terraform, Python-taustajärjestelmät) ja verkkokauppapalvelua: [csitea.net](https://csitea.net).

## 6. 🔧 Tekninen osa: palvelutili

Pilvilevyllä agentti toimii yrityksen varmuuskopioinnin palvelutilinä, ei minun tunnuksillani. Palvelutili näkee vain kansiot, jotka on jaettu sille. Veroasiakirjoille annoin sille yhden juurikansion, kaikkien talousasiakirjojen kansion, ja agentti loi sen alle rakenteen vuosi/kuukausi/vero/tyyppi. Tilin avain on koneella, ei gitissä; koodi lukee avaimen ja kansion nimetyistä muuttujista.

## 7. 🏭 Avointa lähdekoodia

Spool Hub on avointa lähdekoodia (GNU AGPL v3). Lue ja lataa koodi ja aja oma instanssisi pilvessä tai `docker compose` -komennolla: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Haluatko oman demotilin? Ota yhteyttä: [csitea.net](https://csitea.net).
