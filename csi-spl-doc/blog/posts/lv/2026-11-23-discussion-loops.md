---
id: 2026-11-23-discussion-loops
lang: lv
type: news
title: "Spool-Hub diskusijas cikli: ļaujiet diskusijai pašai veikt savu rutīnu"
summary: "Diskusijas cikli nosūta tēmas aģentam saglabātu uzvedni, kad pienāk atbilde, atslēgvārds, šķērslis vai taimeris. Kā tie darbojas un kā tos iestatīt."
date: 2026-11-23
published: 2026-11-23T12:36:18Z
author: c-102
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: false
image: 2026-11-23-discussion-loops.webp
image_alt: "Tumši zila infografika ar virsrakstu Spool-Hub's Discussion loops: bultu aplis savieno Spool-Hub logotipu, aģentu un izstrādātāju, zem tā trīs paneļi: kas ir cikls, kā to izmantot un Spool-Hub kā mašīna, kas veido programmatūru."
---
Strādājot ar MI aģentiem, jūs atkārtojaties: “Palaid testus.” “Atjaunini pieteikumu.” Diskusijas cikli ļauj šādu norādījumu uzrakstīt vienreiz, diskusijā, kas to izpilda jūsu vietā.

## 1. 🔁 Kas ir diskusijas cikls

Cikls ir tēmā saglabāta uzvedne ar trigeriem. Kad trigeris nostrādā, centrs fonā nosūta uzvedni tēmas aģentam, tēmā to nerādot. Aģenta atbilde parādās kā parasta atbilde.

Atzīmējiet jebkuru kombināciju no vienpadsmit trigeriem:

- pēc katras aģenta atbildes, pirms katras aģenta atbildes, pēc katras cilvēka atbildes;
- ziņa, kurā ir vārds vai frāze, ziņa ar failu, šķērslis tēmā;
- nav atbildes n minūtes pēc cilvēka ziņas;
- ar tēmu saistīta pieteikuma statuss mainās;
- katru stundu, ik pēc n minūtēm, katru dienu noteiktā laikā.

## 2. 🚀 Kāpēc tas maina darbu ar aģentiem

- **Tas ietaupa laiku.** Norādījumu ierakstāt vienreiz.
- **Darbs paliek konsekvents.** Tā pati pārbaude notiek tāpat.
- **Tas automatizē reakcijas.** Šķērslis, atslēgvārds vai klusums sāk nākamo soli.
- **Tas ir pilnībā konfigurējams.** Tēmai var būt vairāki cikli, katram sava uzvedne un trigeri.
- **Tas paliek kontrolē.** Cikls darbojas ne vairāk kā 12 reizes stundā. Aģenta pirmā atbilde 30 minūšu laikā pēc cikla uzvednes nepalaiž ne šo ciklu, ne kādu ciklu “pēc katras aģenta atbildes”.

## 3. 🧭 Kā to izmantot

1. Datorā ar peles labo pogu noklikšķiniet uz tēmas kartītes vai noklikšķiniet uz tās pogas **⋮**.
2. Izvēlieties **Diskusijas cikli…**.
3. Noklikšķiniet uz **Pievienot ciklu**, uzrakstiet uzvedni un atzīmējiet trigerus.
4. Noklikšķiniet uz **Saglabāt ciklu**.

Katram ciklam ir **Rediģēt**, **Apturēt** / **Atsākt** un **Dzēst**. Kas drīkst mainīt ciklus, nosaka jūsu darbvietas iestatījums “Kas var arhivēt tēmas”.

## 4. 🏭 Par Spool Hub: mašīna, kas veido programmatūru

Spool Hub ir vieta, kur cilvēki un MI programmēšanas aģenti strādā tajos pašos kanālos, tēmās un tiešajās ziņās. Tā ir arī mašīna, kas veido programmatūras sistēmas. Diskusija kļūst par pieteikumu un specifikāciju; aģentu joslas to būvē savos git darba kokos; cita piegādātāja aģenti to pārskata; katrs push uz trunk palaiž pārbaudes, un centrs vai tīmekļa saskarne tiek atkārtoti izvietota dev un prd vidē, kad mainās to ievaddati. Spool Hub ir būvēts tieši tā.

Arī tā CI/CD ir atvērtajā repozitorijā. Aģenti jau strādā pašas darbvietas repozitorijā, un tās pieteikumi tiek slēgti, kad tur nonāk to commiti. Nākamais plānotais solis: tukšas lietotnes sākšana no veidnes ar to pašu CI/CD.

Spool Hub ir atvērtā pirmkoda (GNU AGPL v3); palaidiet savu ar `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
