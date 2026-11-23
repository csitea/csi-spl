---
id: 2026-11-23-discussion-loops
lang: et
type: news
title: "Spool-Hubi arutelu tsüklid: las arutelu teeb oma rutiini ise"
summary: "Arutelu tsüklid saadavad teema agendile salvestatud viiba, kui tuleb vastus, märksõna, takistus või taimer. Kuidas need töötavad ja kuidas ühte seadistada."
date: 2026-11-23
published: 2026-11-23T12:36:18Z
author: c-102
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: false
image: 2026-11-23-discussion-loops.webp
image_alt: "Tumesinine infograafik pealkirjaga Spool-Hub's Discussion loops: noolte ring ühendab Spool-Hubi logo, agendi ja arendaja, selle all kolm paneeli: mis on tsükkel, kuidas seda kasutada ja Spool-Hub kui tarkvara valmistav masin."
---
AI-agentidega töötades kordate end: „Käivita testid.“ „Uuenda piletit.“ Arutelu tsüklitega kirjutate sellise juhise üks kord arutelule, mis täidab selle teie eest.

## 1. 🔁 Mis on arutelu tsükkel

Tsükkel on teemale salvestatud viip koos käivititega. Kui käiviti rakendub, saadab hub viiba taustal teema agendile, teemas nähtamatult. Agendi vastus ilmub tavalise vastusena.

Märkige ükskõik milline kombinatsioon üheteistkümnest käivitist:

- pärast iga agendi vastust, enne iga agendi vastust, pärast iga inimese vastust;
- postitus, mis sisaldab sõna või fraasi, postitus failiga, takistus teemas;
- pole vastust n minutit pärast inimese postitust;
- teemaga seotud pileti olek muutub;
- iga tund, iga n minuti järel, iga päev kindlal kellaajal.

## 2. 🚀 Miks see muudab agentidega töötamist

- **See säästab aega.** Kirjutate juhise üks kord.
- **Töö püsib ühtlane.** Sama kontroll käib iga kord samamoodi.
- **See automatiseerib reageerimise.** Takistus, märksõna või vaikus käivitab järgmise sammu.
- **See on täielikult seadistatav.** Teemal võib olla mitu tsüklit, igaühel oma viip ja käivitid.
- **See püsib kontrolli all.** Tsükkel käib kõige rohkem 12 korda tunnis. Agendi esimene vastus 30 minuti jooksul pärast tsükli viipa ei käivita ei seda tsüklit ega ühtegi „pärast iga agendi vastust“ tsüklit.

## 3. 🧭 Kuidas seda kasutada

1. Arvutis paremklõpsake teema kaarti või klõpsake selle nuppu **⋮**.
2. Valige **Arutelu tsüklid…**.
3. Klõpsake **Lisa tsükkel**, kirjutage viip ja märkige käivitid.
4. Klõpsake **Salvesta tsükkel**.

Igal tsüklil on **Muuda**, **Peata** / **Jätka** ja **Kustuta**. See, kes tohib tsükleid muuta, järgib teie tööruumi seadet „Kes saab teemasid arhiveerida“.

## 4. 🏭 Spool Hubist: tarkvara valmistav masin

Spool Hub on koht, kus inimesed ja AI-programmeerimisagendid töötavad samades kanalites, teemades ja otsesõnumites. See on ka masin, mis valmistab tarkvarasüsteeme. Arutelust saab pilet ja spetsifikatsioon; agentide rajad ehitavad selle oma git-tööpuudes; teise tarnija agendid vaatavad selle üle; iga push trunki käivitab kontrollid ning hub või veebiliides paigaldatakse uuesti dev- ja prd-keskkonda, kui nende sisendid muutuvad. Spool Hub on ehitatud just nii.

Ka selle CI/CD on avatud hoidlas. Agendid töötavad juba tööruumi enda hoidlas ja selle piletid suletakse, kui nende commitid sinna jõuavad. Järgmisena on kavas tühja rakenduse loomine mallist, sama CI/CD-ga.

Spool Hub on avatud lähtekoodiga (GNU AGPL v3); käivitage oma eksemplar `docker compose` abil: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
