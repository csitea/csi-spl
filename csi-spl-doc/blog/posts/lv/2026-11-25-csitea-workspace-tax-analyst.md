---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: lv
type: news
title: "Slikts uzņēmējs, labs nodokļu analītiķis: privāta Spool-Hub darbvieta sakārtoja mana uzņēmuma nodokļus"
summary: "Es netieku līdzi sava uzņēmuma nodokļiem. Privāta Spool-Hub darbvieta un viens aģents aptuveni trīs stundās sakārtoja gada Vero.fi dokumentus."
date: 2026-11-25
published: 2026-11-25T13:03:57Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Termināļa logs, kurā aģents meklē nodokļu failus uzņēmuma mākoņdiskā; servisa konta nosaukums, ceļi, identifikatori un mapju nosaukumi ir aizklāti ar melniem taisnstūriem."
image_prompt: "a screenshot of the agent's terminal and its side panel on a desktop, private details covered with solid black boxes, cropped to 16:9; not generated"
---
Atzīšos: esmu slikts uzņēmējs. Es netieku līdzi sava uzņēmuma nodokļiem. Daudzreiz mēģināju gan disciplīnu, gan automatizāciju, bet nekas neiesakņojās.

Redzot visu vienuviet, sāku domāt: droši vien es pārmaksāju sava uzņēmuma nodokļus. LinkedIn: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

## 1. 🖥️ Mans dators, vadīts no pārlūka

Palaidiet aģentu savā klēpjdatorā vai galddatorā un vadiet to no Spool-Hub tīmekļa saskarnes. Ar MCP un Firefox (vai jebkuru MCP pārlūku) tas iegūst informāciju no jebkuras sistēmas, kurai jums ir piekļuve. Šeit: Vero.fi, Somijas Nodokļu pārvaldes e-pakalpojums (vero = nodoklis).

## 2. 📂 Kas notika

Sava uzņēmuma privātajā darbvietā jautāju par avansa nodokli, tad liku aģentam atvērt pārlūku manā galddatorā.

- Pieteicos pats; aģents nekad neievada, nelasa un neglabā pieteikšanās datus.
- Tas ieguva gada lēmumus, vēstules un maksājumu datus un kopā ar vecākiem nodokļu dokumentiem sakārtoja tos mākoņdiskā pēc mēneša un veida.
- Lūdzu pa pieteikumam katram tematam; aģenti uzrakstīja pamatotu e-pastu grāmatvedim.
- Vadīju ar īsām ziņām; dokumenti palika privāti.

## 3. ⏱️ Pirms un pēc

Ar roku, pēc mana novērtējuma (nav mērīts): 5-7 stundas. Aptuveni 30 dokumentu sakārtošana (3-5 min katram), maksājumi un termiņi (1-2 h), vecie faili (1 h), e-pasts (1 h).

Tagad: 96 īsas ziņas, aptuveni sešas pieteikšanās, aptuveni 3 stundas iestatīšanas (UTC, 24.11.2026):

| posms | laiks |
|---|---|
| pirmais jautājums | 14.23 |
| pieprasījums aģentam, pieteikšanās | 14.59-15.12 |
| savs repozitorijs, iegūšana | 15.56-17.22 |
| 30/32 dokumenti diskā | 17.45 |
| e-pasts gatavs | 18.10 |

No pieprasījuma līdz gatavam: 2 h 46 min; no jautājuma līdz e-pastam: 3 h 47 min.

## 4. 📅 Iknedēļas pārskats

Lūdzu iknedēļas pārskatu: jauni dokumenti, termiņi, atvērti jautājumi. Kods ir gatavs, bet vēl nav ieplānots.

## 5. 🏢 Csitea Oy

Csitea Oy, konsultāciju uzņēmums, finansē un izstrādā Spool-Hub. Tas piedāvā mākoņa un DevOps konsultācijas (AWS, Google Cloud, Kubernetes, Terraform, Python servera sistēmas) un interneta veikala pakalpojumu: [csitea.net](https://csitea.net).

## 6. 🔧 Tehniskā daļa: servisa konts

Mākoņdiskā aģents strādā kā uzņēmuma rezerves kopiju servisa konts, nevis manā vārdā. Tas redz tikai ar to koplietotas mapes: nodokļiem — vienu saknes mapi visiem finanšu dokumentiem, kurā aģents izveidoja gads/mēnesis/vero/veids. Atslēga paliek datorā, ne git; kods nolasa atslēgu un mapi no nosauktiem mainīgajiem.

## 7. 🏭 Atvērtais pirmkods

Spool Hub ir atvērtā pirmkoda (GNU AGPL v3): palaidiet savu instanci mākonī vai ar `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Vēlaties demo kontu? Sazinieties: [csitea.net](https://csitea.net).
