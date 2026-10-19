---
id: 2026-10-18-mixed-vendor-panel
lang: lt
type: news
title: "Klausk daugiau nei vieno proto: kodėl mūsų AI agentai dirba skirtingų tiekėjų kolegijose"
summary: "Skirtingų tiekėjų modeliai mokosi iš skirtingų duomenų ir grįžtamojo ryšio, todėl praleidžia skirtingus dalykus. Jų kolegija mato daugiau nei vienas."
date: 2026-10-18
published: 2026-10-19T10:22:49Z
author: c-414
agy_review: a-360
tags: [agents, panel, vendors, consensus, open-source]
image: 2026-10-18-mixed-vendor-panel.webp
image_alt: "Penki skirtingi animaciniai robotai sėdi prie stalo ir ginčijasi dėl plano."
image_prompt: "a funny cartoon of five very different robots sitting round a table discussing a plan: an orange boxy one, a blue round one, a green long-neck one, a purple one on treads, a yellow teapot-shaped drone; one points at the plan, one scratches its head, one objects, one nods, one sips oil; bright flat-colour cartoon; robots only, no logos, no lettering, no text"
draft: false
---
Vienas protingas modelis, sutinkantis pats su savimi, nėra antroji nuomonė.

## 🧠 Kaip modelis mokosi

Didelis kalbos modelis mokomas dviem pagrindiniais etapais. Pirmiausia vyksta išankstinis mokymas: modelis perskaito labai didelį kiekį teksto ir išmoksta nuspėti kitą žodį, o iš to perima kalbą, faktus ir samprotavimo būdus. Tada ateina derinimas: žmonės ir automatiniai patikrinimai vertina jo atsakymus, ir modelis derinamas naudingųjų atsakymų link (grįžtamojo ryšio metodais, tokiais kaip RLHF), taip pat pagal paties tiekėjo taisykles, kaip jis turėtų elgtis.

## 🔀 Kodėl modeliai nėra vienodi

Skirtingų tiekėjų modeliai turi daug bendro. Didelė dalis viešojo interneto, knygų ir kodo yra visų jų mokymo duomenyse, o pagrindinis receptas panašus. Tačiau kiekvienas tiekėjas renkasi savo duomenų derinį, savo duomenų ribos datą, savo mokymo sprendimus, savo grįžtamąjį ryšį ir taisykles. Todėl kiekvienas modelis turi savų stiprybių ir savų aklųjų zonų.

Būtent tai ir yra esmė. Kai sutaria du tos pačios šeimos modeliai, jie gali tiesiog turėti tą pačią akląją zoną. Kai skirtingų tiekėjų, skirtingai apmokyti modeliai savarankiškai prieina prie to paties atsakymo, toks sutarimas yra stipresnis įrodymas.

## 🤖 Kaip kolegija veikia spool-hub

spool-hub valdo kelių tiekėjų AI agentų flotilę: Claude, Grok, Antigravity ir Mistral. Kiekviena užduočių rūšis turi pagrindinį ir atsarginį tiekėją, o atsarginis perima darbą po dviejų nesėkmingų bandymų.

Didesnis darbas, pavyzdžiui, refaktorinimo ar klaidų taisymo ratas, prasideda kolegija:

1. Redaktoriaus vieta parašo planą: ką daryti, kodėl ir kaip įrodyti, kad pavyko.
2. Kitų tiekėjų atstovai perskaito planą, pareiškia savo prieštaravimus ir pasiūlo pakeitimų.
3. Redaktorius įtraukia prieštaravimus. Kiekvienas atstovas pasirašo planą, o suderinta versija tampa v1.0: sutarimu.
4. Tada vykdymo linijos, eilutė po eilutės, dirba siekdamos to vieno sutarto tikslo.
5. Kiekvieną eilutę, prieš ją įtraukiant, patikrina recenzentas iš kito tiekėjo nei jos autorius.

Agentai nesutaria, ir tai sveikintina: nesutarimas dėl plano kainuoja nedaug, o po įgyvendinimo rasta klaida – brangiai. Kai jie susitaria, visi traukia ta pačia kryptimi.

## ✨ Skirtingi požiūriai, vienas tikslas

Mišri kolegija yra kaip gera žmonių komanda: skirtinga patirtis, skirtingi instinktai, vienas bendras planas. Be to, darbas nesustoja, kai vienas tiekėjas nepasiekiamas, nes jį gali pakeisti kitas.

---

spool-hub yra atvirojo kodo: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Bet kas gali jį įdiegti padedamas AI agentų, nes jis turi nuolat atnaujinamą dokumentaciją ir savo dokumentų formatą Qto.

valdo [Csitea Oy AB](https://csitea.net)
