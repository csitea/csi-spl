---
id: 2026-10-18-mixed-vendor-panel
lang: lv
type: news
title: "Jautā vairāk nekā vienam prātam: kāpēc mūsu AI aģenti strādā dažādu piegādātāju padomēs"
summary: "Dažādu piegādātāju modeļi mācās no atšķirīgiem datiem un atsauksmēm, tāpēc palaiž garām dažādas lietas. To padome redz vairāk nekā viens modelis."
date: 2026-10-18
published: 2026-10-19T10:22:49Z
author: c-414
agy_review: a-360
tags: [agents, panel, vendors, consensus, open-source]
image: 2026-10-18-mixed-vendor-panel.webp
image_alt: "Pieci dažādi multfilmu roboti sēž ap galdu un strīdas par plānu."
image_prompt: "a funny cartoon of five very different robots sitting round a table discussing a plan: an orange boxy one, a blue round one, a green long-neck one, a purple one on treads, a yellow teapot-shaped drone; one points at the plan, one scratches its head, one objects, one nods, one sips oil; bright flat-colour cartoon; robots only, no logos, no lettering, no text"
draft: false
---
Viens gudrs modelis, kas piekrīt pats sev, nav otrs viedoklis.

## 🧠 Kā modelis mācās

Lielu valodas modeli apmāca divos galvenajos soļos. Vispirms notiek priekšapmācība: modelis izlasa ļoti lielu tekstu apjomu un iemācās paredzēt nākamo vārdu, un no tā tas apgūst valodu, faktus un spriešanas paraugus. Pēc tam seko pielāgošana: cilvēki un automātiskas pārbaudes vērtē tā atbildes, un modeli pielāgo noderīgo atbilžu virzienā (ar atgriezeniskās saites metodēm, piemēram, RLHF), kā arī tā piegādātāja noteikumiem par to, kā tam jāuzvedas.

## 🔀 Kāpēc modeļi nav vienādi

Dažādu piegādātāju modeļiem ir daudz kopīga. Liela daļa publiskā tīmekļa, grāmatu un koda ir visu to apmācības datos, un pamatrecepte ir līdzīga. Taču katrs piegādātājs izvēlas savu datu kopumu, savu datu robežas datumu, savas apmācības izvēles un savu atgriezenisko saiti un noteikumus. Tāpēc katram modelim ir savas stiprās puses un savas aklās zonas.

Tieši tur ir būtība. Ja divi vienas saimes modeļi ir vienisprātis, tiem var vienkārši būt viena un tā pati aklā zona. Ja dažādu piegādātāju, atšķirīgi apmācīti modeļi katrs pats nonāk pie vienas un tās pašas atbildes, šāda vienprātība ir spēcīgāks pierādījums.

## 🤖 Kā padome strādā spool-hub

spool-hub darbina vairāku piegādātāju AI aģentu floti: Claude, Grok, Antigravity un Mistral. Katram uzdevumu veidam ir galvenais un rezerves piegādātājs, un rezerves piegādātājs pārņem darbu pēc diviem neveiksmīgiem mēģinājumiem.

Lielāks darbs, piemēram, refaktorēšanas vai kļūdu labošanas kārta, sākas ar padomi:

1. Redaktora loma uzraksta plānu: ko darīt, kāpēc un kā pierādīt, ka tas izdevās.
2. Citu piegādātāju pārstāvji izlasa plānu, izsaka savus iebildumus un ierosina izmaiņas.
3. Redaktors iestrādā iebildumus. Katrs pārstāvis paraksta plānu, un saskaņotā versija kļūst par v1.0: vienprātību.
4. Pēc tam izstrādes joslas rindu pēc rindas strādā pie šī viena saskaņotā mērķa.
5. Katru rindu pirms iekļaušanas pārbauda recenzents, kura piegādātājs atšķiras no autora piegādātāja.

Aģenti strīdas, un tas ir apsveicami: domstarpības par plānu izmaksā maz, bet pēc izstrādes atrasta kļūda izmaksā dārgi. Kad viņi ir vienojušies, visi velk vienā virzienā.

## ✨ Dažādi skatījumi, viens mērķis

Jaukta padome ir kā laba cilvēku komanda: atšķirīga pieredze, atšķirīgi instinkti, viens kopīgs plāns. Tā arī ļauj darbam turpināties, kad viens piegādātājs nav pieejams, jo cits var stāties tā vietā.

---

spool-hub ir atvērtā koda projekts: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Ikviens to var uzstādīt ar AI aģentu palīdzību, pateicoties tā aktuālajai dokumentācijai un savam dokumentu formātam Qto.

uztur [Csitea Oy AB](https://csitea.net)
