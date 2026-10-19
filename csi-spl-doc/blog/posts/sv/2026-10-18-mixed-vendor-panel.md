---
id: 2026-10-18-mixed-vendor-panel
lang: sv
type: news
title: "Fråga fler än ett sinne: därför sitter våra AI-agenter i paneler med flera leverantörer"
summary: "Modeller från olika leverantörer lär sig av olika data och olika återkoppling, så de missar olika saker. En panel av dem ser mer än en ensam modell."
date: 2026-10-18
published: 2026-10-19T10:22:49Z
author: c-414
agy_review: a-360
tags: [agents, panel, vendors, consensus, open-source]
image: 2026-10-18-mixed-vendor-panel.webp
image_alt: "Fem olika tecknade robotar sitter runt ett bord och diskuterar en plan."
image_prompt: "a funny cartoon of five very different robots sitting round a table discussing a plan: an orange boxy one, a blue round one, a green long-neck one, a purple one on treads, a yellow teapot-shaped drone; one points at the plan, one scratches its head, one objects, one nods, one sips oil; bright flat-colour cartoon; robots only, no logos, no lettering, no text"
draft: false
---
En smart modell som håller med sig själv är ingen second opinion.

## 🧠 Hur en modell lär sig

En stor språkmodell tränas i två stora steg. Först kommer förträningen: den läser en mycket stor mängd text och lär sig förutsäga nästa ord, och på så sätt tar den till sig språk, fakta och mönster för resonemang. Sedan kommer finjusteringen: människor och automatiska kontroller betygsätter dess svar, och den justeras mot de hjälpsamma (med återkopplingsmetoder som RLHF) och mot leverantörens egna regler för hur den ska bete sig.

## 🔀 Varför modellerna inte är likadana

Olika leverantörers modeller har mycket gemensamt. En stor del av den öppna webben, böcker och kod finns i allas träningsdata, och grundreceptet är likartat. Men varje leverantör väljer sin egen datamix, sitt eget brytdatum, sina egna träningsval och sin egen återkoppling och sina egna regler. Därför har varje modell sina egna styrkor – och sina egna blinda fläckar.

Det är just poängen. När två modeller från samma familj håller med varandra kan de helt enkelt ha samma blinda fläck. När modeller från olika leverantörer, tränade på olika sätt, kommer fram till samma svar var för sig är den enigheten ett starkare belägg.

## 🤖 Så fungerar en panel i spool-hub

spool-hub kör en flotta av AI-agenter från flera leverantörer: Claude, Grok, Antigravity och Mistral. Varje typ av uppgift har en huvudleverantör och en reserv, och reserven tar över efter två misslyckade försök.

Större arbeten, som en omgång refaktorering eller buggfixar, börjar med en panel:

1. En redaktörsplats skriver en plan: vad som ska göras, varför och hur man bevisar att det fungerade.
2. Representanter från andra leverantörer läser planen, framför sina invändningar och föreslår ändringar.
3. Redaktören arbetar in invändningarna. Varje representant skriver under planen, och den överenskomna versionen blir v1.0: konsensus.
4. Byggspåren arbetar sedan mot det enda överenskomna målet, rad för rad.
5. Varje rad granskas innan den landar av en granskare från en annan leverantör än dess upphovsperson.

Agenterna är oense, och det är välkommet: en oenighet om planen är billig, medan ett misstag som upptäcks efter bygget inte är det. När de väl är överens drar alla åt samma håll.

## ✨ Olika synsätt, ett mål

En blandad panel är som ett bra team av människor: olika bakgrunder, olika instinkter, en gemensam plan. Den håller också arbetet igång när en leverantör ligger nere, eftersom en annan kan kliva in.

---

spool-hub är öppen källkod: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Vem som helst kan installera det med hjälp av AI-agenter, tack vare aktuell dokumentation och ett eget dokumentformat, Qto.

drivs av [Csitea Oy AB](https://csitea.net)
