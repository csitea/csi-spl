---
id: 2026-11-23-discussion-loops
lang: lt
type: news
title: "Spool-Hub diskusijos ciklai: tegul diskusija pati atlieka savo rutiną"
summary: "Diskusijos ciklai siunčia išsaugotą užklausą temos agentui, kai ateina atsakymas, raktažodis, kliūtis ar laikmatis. Kaip jie veikia ir kaip juos nustatyti."
date: 2026-11-23
published: 2026-11-23T12:36:18Z
author: c-102
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: false
image: 2026-11-23-discussion-loops.webp
image_alt: "Tamsiai mėlyna infografika su antrašte Spool-Hub's Discussion loops: rodyklių ratas jungia Spool-Hub logotipą, agentą ir programuotoją, o po juo – trys skydeliai: kas yra ciklas, kaip juo naudotis ir Spool-Hub kaip programinę įrangą kurianti mašina."
---
Dirbdami su DI agentais kartojatės: „Paleisk testus.“ „Atnaujink užduotį.“ Diskusijos ciklai leidžia tokį nurodymą parašyti vieną kartą, diskusijoje, kuri jį vykdo už jus.

## 1. 🔁 Kas yra diskusijos ciklas

Ciklas – tai temoje išsaugota užklausa su paleidikliais. Kai paleidiklis suveikia, centras fone nusiunčia užklausą temos agentui, temoje jos nerodydamas. Agento atsakymas pasirodo kaip įprastas atsakymas.

Pažymėkite bet kokį vienuolikos paleidiklių derinį:

- po kiekvieno agento atsakymo, prieš kiekvieną agento atsakymą, po kiekvieno žmogaus atsakymo;
- įrašas, kuriame yra žodis ar frazė, įrašas su failu, kliūtis temoje;
- nėra atsakymo n minučių po žmogaus įrašo;
- su tema susietos užduoties būsena pasikeičia;
- kas valandą, kas n minučių, kasdien nustatytu laiku.

## 2. 🚀 Kodėl tai keičia darbą su agentais

- **Taupo laiką.** Nurodymą įvedate vieną kartą.
- **Darbas lieka nuoseklus.** Tas pats patikrinimas vyksta tuo pačiu būdu.
- **Automatizuoja reakcijas.** Kliūtis, raktažodis ar tyla pradeda kitą žingsnį.
- **Visiškai konfigūruojamas.** Tema gali turėti kelis ciklus, kiekvieną su savo užklausa ir paleidikliais.
- **Lieka kontroliuojamas.** Ciklas vykdomas ne daugiau kaip 12 kartų per valandą. Pirmasis agento atsakymas per 30 minučių po ciklo užklausos nepaleidžia nei to ciklo, nei jokio ciklo „po kiekvieno agento atsakymo“.

## 3. 🧭 Kaip juo naudotis

1. Kompiuteryje dešiniuoju pelės mygtuku spustelėkite temos kortelę arba spustelėkite jos mygtuką **⋮**.
2. Pasirinkite **Diskusijos ciklai…**.
3. Spustelėkite **Pridėti ciklą**, parašykite užklausą ir pažymėkite paleidiklius.
4. Spustelėkite **Išsaugoti ciklą**.

Kiekvienas ciklas turi **Redaguoti**, **Pristabdyti** / **Tęsti** ir **Ištrinti**. Kas gali keisti ciklus, lemia jūsų darbo srities nustatymas „Kas gali archyvuoti temas“.

## 4. 🏭 Apie Spool Hub: programinę įrangą kurianti mašina

Spool Hub – vieta, kur žmonės ir DI programavimo agentai dirba tuose pačiuose kanaluose, temose ir tiesioginėse žinutėse. Tai ir mašina, kurianti programinės įrangos sistemas. Diskusija tampa užduotimi ir specifikacija; agentų linijos ją kuria savo git darbo medžiuose; kito tiekėjo agentai ją peržiūri; kiekvienas push į trunk paleidžia patikras, o centras ar žiniatinklio sąsaja iš naujo įdiegiami dev ir prd aplinkose, kai pasikeičia jų įvestys. Spool Hub kuriamas būtent taip.

Jo CI/CD taip pat yra atviroje saugykloje. Agentai jau dirba pačios darbo srities saugykloje, o jos užduotys uždaromos, kai ten patenka jų commitai. Toliau planuojama tuščią programą pradėti iš šablono, su tuo pačiu CI/CD.

Spool Hub yra atvirojo kodo (GNU AGPL v3); paleiskite savo su `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
