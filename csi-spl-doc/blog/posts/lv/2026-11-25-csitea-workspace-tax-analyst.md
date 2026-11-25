---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: lv
type: news
title: "Slikts uzņēmējs, labs nodokļu analītiķis: privāta Spool-Hub darbvieta sakārtoja mana uzņēmuma nodokļus"
summary: "Es netieku līdzi sava uzņēmuma nodokļiem. Privāta Spool-Hub darbvieta un viens aģents aptuveni trīs stundās sakārtoja gada Vero.fi dokumentus."
date: 2026-11-25
published: 2026-11-25T13:55:48Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Infografika: uzņēmējs ar nodokļu papīru kaudzēm, robots nodokļu analītiķis, centrā privāta Spool-Hub darba telpa, aģents caur MCP pārlūkā atver Vero.fi, dokumenti mākoņdiskā sakārtoti gada, nodokļu un maksājumu mapēs, e-pasts grāmatvedim un laiki: ar roku 5-7 stundas, iestatīšana un automatizācija 3 stundas, nākamreiz 15 minūtes."
image_prompt: "the owner's own infographic (made with Gemini), published as-is; centre-cropped to 16:9 by the blog encoder"
---
Atzīšos: esmu slikts uzņēmējs. Es netieku līdzi sava uzņēmuma nodokļiem. Daudzreiz mēģināju gan disciplīnu, gan automatizāciju, bet nekas neiesakņojās.

Redzot visu vienuviet, sāku domāt: droši vien es pārmaksāju sava uzņēmuma nodokļus. LinkedIn: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

Tālāk – automatizācija: skripti kopā ar Spool-Hub plānošanu un infrastruktūru, lai iknedēļas pārbaude notiktu pati. Skripti ir publiski: [github.com/csitea/csi-tax](https://github.com/csitea/csi-tax).

## 1. 🖥️ Mans dators, vadīts no pārlūka

Palaidiet aģentu savā klēpjdatorā vai galddatorā un vadiet to no Spool-Hub tīmekļa saskarnes. Ar MCP un Firefox (vai jebkuru MCP pārlūku) tas iegūst informāciju no jebkuras sistēmas, kurai jums ir piekļuve. Šeit: Vero.fi, Somijas Nodokļu pārvaldes e-pakalpojums (vero = nodoklis).

## 2. 📂 Kas notika

Sava uzņēmuma privātajā darbvietā jautāju par avansa nodokli, tad liku aģentam atvērt pārlūku manā galddatorā.

- Pieteicos pats; aģents nekad neievada, nelasa un neglabā pieteikšanās datus.
- Tas ieguva gada lēmumus, vēstules un maksājumu datus un kopā ar vecākiem nodokļu dokumentiem sakārtoja tos mākoņdiskā pēc mēneša un veida.
- Lūdzu pa pieteikumam katram tematam; aģenti uzrakstīja pamatotu e-pastu grāmatvedim.
- Vadīju ar īsām ziņām; dokumenti palika privāti.

## 3. ⏱️ Pirms un pēc

Ar roku tas aizņēma 5-7 stundas.

Tagad: 96 īsas ziņas, aptuveni sešas pieteikšanās un aptuveni 3 stundas, kas tika veltītas automatizācijas un iestatīšanas izveidei (UTC, 24.11.2026):

| posms | laiks |
|---|---|
| pirmais jautājums | 14.23 |
| pieprasījums aģentam, pieteikšanās | 14.59-15.12 |
| savs repozitorijs, iegūšana | 15.56-17.22 |
| 30/32 dokumenti diskā | 17.45 |
| e-pasts gatavs | 18.10 |

Turpmāk tam pašam nodokļu darbam vajadzētu aizņemt mazāk nekā 15 minūtes nedēļā.

## 4. 📅 Iknedēļas pārskats

Lūdzu iknedēļas pārskatu: jauni dokumenti, termiņi, atvērti jautājumi. Kods ir gatavs, bet vēl nav ieplānots.

## 5. 🏢 Csitea Oy

Csitea Oy, konsultāciju uzņēmums, finansē un izstrādā Spool-Hub. Tas piedāvā mākoņa un DevOps konsultācijas (AWS, Google Cloud, Kubernetes, Terraform, Python servera sistēmas) un interneta veikala pakalpojumu: [csitea.net](https://csitea.net).

## 6. 🔧 Tehniskā daļa: servisa konts

Mākoņdiskā aģents strādā kā uzņēmuma rezerves kopiju servisa konts, nevis manā vārdā. Tas redz tikai ar to koplietotas mapes: nodokļiem — vienu saknes mapi visiem finanšu dokumentiem, kurā aģents izveidoja gads/mēnesis/vero/veids. Atslēga paliek datorā, ne git; kods nolasa atslēgu un mapi no nosauktiem mainīgajiem.

## 7. 🏭 Atvērtais pirmkods

Spool Hub ir atvērtā pirmkoda (GNU AGPL v3): palaidiet savu instanci mākonī vai ar `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Vēlaties demo kontu? Sazinieties: [csitea.net](https://csitea.net).
