---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: et
type: news
title: "Halb ettevõtja, hea maksuanalüütik: privaatne Spool-Hubi tööruum korraldas mu ettevõtte maksud"
summary: "Ma ei suuda oma ettevõtte maksudel silma peal hoida. Privaatne Spool-Hubi tööruum ja üks agent korrastasid aasta Vero.fi dokumendid umbes kolme tunniga."
date: 2026-11-25
published: 2026-11-25T13:55:48Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Terminaliaken, kus agent otsib ettevõtte pilvekettalt maksufaile; teenusekonto nimi, teed, ID-d ja kaustade nimed on kaetud mustade kastidega."
image_prompt: "a screenshot of the agent's terminal and its side panel on a desktop, private details covered with solid black boxes, cropped to 16:9; not generated"
---
Tunnistan: olen halb ettevõtja. Ma ei suuda oma ettevõtte maksudel silma peal hoida. Proovisin korduvalt distsipliini ja automatiseerimist; miski ei jäänud püsima.

Kui nägin kõike ühes kohas, hakkasin mõtlema: tõenäoliselt maksan oma ettevõtte eest liiga palju makse. LinkedInis: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

## 1. 🖥️ Minu arvuti, juhitud brauserist

Käivitage agent oma sülearvutis või lauaarvutis ja juhtige seda Spool-Hubi veebiliidesest. MCP ja Firefoxi (või mis tahes MCP-brauseri) abil hangib see teavet igast süsteemist, millele teil on ligipääs. Siin: Vero.fi, Soome Maksuameti e-teenus (vero = maks).

## 2. 📂 Mis juhtus

Oma ettevõtte privaatses tööruumis küsisin avansilise maksu kohta ja lasin siis agendil avada mu lauaarvutis brauseri.

- Logisin ise sisse; agent ei trüki, loe ega salvesta kunagi kasutajatunnuseid.
- See hankis aasta otsused, kirjad ja makseandmed ning paigutas need koos vanemate maksudokumentidega pilvekettale kuu ja tüübi järgi.
- Palusin iga teema kohta pileti; agendid kirjutasid raamatupidajale põhjendatud e-kirja.
- Juhtisin lühikeste sõnumitega; dokumendid jäid privaatseks.

## 3. ⏱️ Enne ja pärast

Käsitsi, minu hinnangul (mõõtmata): 5-7 tundi. Umbes 30 dokumenti paigutatud (3-5 min tükk), maksed ja tähtajad (1-2 h), vanad failid (1 h), e-kiri (1 h).

Nüüd: 96 lühikest sõnumit, umbes kuus sisselogimist, umbes 3 tundi seadistamist (UTC, 24.11.2026):

| etapp | aeg |
|---|---|
| esimene küsimus | 14.23 |
| agendi taotlus, sisselogimine | 14.59-15.12 |
| oma hoidla, allalaadimine | 15.56-17.22 |
| 30/32 dokumenti kettal | 17.45 |
| e-kiri valmis | 18.10 |

Taotlusest valmimiseni: 2 h 46 min; küsimusest e-kirjani: 3 h 47 min.

## 4. 📅 Nädalaaruanne

Palusin nädalaaruannet: uued dokumendid, tähtajad, lahtised küsimused. Kood on valmis, kuid veel ajastamata.

## 5. 🏢 Csitea Oy

Csitea Oy, konsultatsiooniettevõte, rahastab ja arendab Spool-Hubi. See pakub pilve- ja DevOps-konsultatsioone (AWS, Google Cloud, Kubernetes, Terraform, Pythoni taustasüsteemid) ja veebipoe teenust: [csitea.net](https://csitea.net).

## 6. 🔧 Tehniline osa: teenusekonto

Pilvekettal töötab agent ettevõtte varunduse teenusekontona, mitte minuna. See näeb ainult temaga jagatud kaustu: maksude jaoks üht juurkausta kõigi finantsdokumentide jaoks, kuhu agent ehitas aasta/kuu/vero/tüüp. Võti jääb masinasse, mitte giti; kood loeb võtme ja kausta nimetatud muutujatest.

## 7. 🏭 Avatud lähtekood

Spool Hub on avatud lähtekoodiga (GNU AGPL v3): käitage oma eksemplari pilves või `docker compose` abil: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Demokonto? Võtke ühendust: [csitea.net](https://csitea.net).
