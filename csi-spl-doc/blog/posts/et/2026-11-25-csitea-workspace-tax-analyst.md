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
image_alt: "Infograafik: ettevõtja maksupaberite hunnikutega, robotist maksuanalüütik, keskel privaatne Spool-Hubi tööruum, agent avab MCP kaudu brauseris Vero.fi, dokumendid pilvekettal aasta-, maksu- ja maksekaustades, e-kiri raamatupidajale ning ajad: käsitsi 5-7 tundi, seadistus ja automatiseerimine 3 tundi, järgmisel korral 15 minutit."
image_prompt: "the owner's own infographic (made with Gemini), published as-is; centre-cropped to 16:9 by the blog encoder"
---
Tunnistan: olen halb ettevõtja. Ma ei suuda oma ettevõtte maksudel silma peal hoida. Proovisin korduvalt distsipliini ja automatiseerimist; miski ei jäänud püsima.

Kui nägin kõike ühes kohas, hakkasin mõtlema: tõenäoliselt maksan oma ettevõtte eest liiga palju makse. LinkedInis: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

Järgmiseks automatiseerimine: skriptid koos Spool-Hubi ajastuse ja taristuga, et iganädalane kontroll jookseks iseenesest. Skriptid on avalikud: [github.com/csitea/csi-tax](https://github.com/csitea/csi-tax).

## 1. 🖥️ Minu arvuti, juhitud brauserist

Käivitage agent oma sülearvutis või lauaarvutis ja juhtige seda Spool-Hubi veebiliidesest. MCP ja Firefoxi (või mis tahes MCP-brauseri) abil hangib see teavet igast süsteemist, millele teil on ligipääs. Siin: Vero.fi, Soome Maksuameti e-teenus (vero = maks).

## 2. 📂 Mis juhtus

Oma ettevõtte privaatses tööruumis küsisin avansilise maksu kohta ja lasin siis agendil avada mu lauaarvutis brauseri.

- Logisin ise sisse; agent ei trüki, loe ega salvesta kunagi kasutajatunnuseid.
- See hankis aasta otsused, kirjad ja makseandmed ning paigutas need koos vanemate maksudokumentidega pilvekettale kuu ja tüübi järgi.
- Palusin iga teema kohta pileti; agendid kirjutasid raamatupidajale põhjendatud e-kirja.
- Juhtisin lühikeste sõnumitega; dokumendid jäid privaatseks.

## 3. ⏱️ Enne ja pärast

Käsitsi kulus 5-7 tundi.

Nüüd: 96 lühikest sõnumit, umbes kuus sisselogimist ja umbes 3 tundi, mis kulusid automatiseerimise ja seadistuse loomisele (UTC, 24.11.2026):

| etapp | aeg |
|---|---|
| esimene küsimus | 14.23 |
| agendi taotlus, sisselogimine | 14.59-15.12 |
| oma hoidla, allalaadimine | 15.56-17.22 |
| 30/32 dokumenti kettal | 17.45 |
| e-kiri valmis | 18.10 |

Edaspidi peaks sama maksutöö võtma alla 15 minuti nädalas.

## 4. 📅 Nädalaaruanne

Palusin nädalaaruannet: uued dokumendid, tähtajad, lahtised küsimused. Kood on valmis, kuid veel ajastamata.

## 5. 🏢 Csitea Oy

Csitea Oy, konsultatsiooniettevõte, rahastab ja arendab Spool-Hubi. See pakub pilve- ja DevOps-konsultatsioone (AWS, Google Cloud, Kubernetes, Terraform, Pythoni taustasüsteemid) ja veebipoe teenust: [csitea.net](https://csitea.net).

## 6. 🔧 Tehniline osa: teenusekonto

Pilvekettal töötab agent ettevõtte varunduse teenusekontona, mitte minuna. See näeb ainult temaga jagatud kaustu: maksude jaoks üht juurkausta kõigi finantsdokumentide jaoks, kuhu agent ehitas aasta/kuu/vero/tüüp. Võti jääb masinasse, mitte giti; kood loeb võtme ja kausta nimetatud muutujatest.

## 7. 🏭 Avatud lähtekood

Spool Hub on avatud lähtekoodiga (GNU AGPL v3): käitage oma eksemplari pilves või `docker compose` abil: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Demokonto? Võtke ühendust: [csitea.net](https://csitea.net).
