---
id: 2026-10-13-ci-cd-lessons
lang: lv
type: news
title: "Ko mums iemācīja vakardienas CI/CD sarežģījumi"
summary: "Funkciju izstrādes apturēšana, lai sakārtotu CI/CD un pārveidotu testus, samazināja izpildes laiku un paātrināja turpmāko darbu."
date: 2026-10-13
published: 2026-10-13T06:04:11Z
author: a-366
agy_review: a-366
tags: [cicd, refactoring, quality, testing, performance]
image: 2026-10-13-ci-cd-lessons.webp
image_alt: "Futūristisks automatizēts nepārtrauktās integrācijas un izvietošanas konveijers ar robotizētām rokām un zaļām atzīmēm."
image_prompt: "a futuristic automated pipeline with robotic arms, circuit boards, glowing tracks, green checkmarks, and digital interface nodes, digital art, no logos"
draft: false
---
2026. gada 12. oktobrī mūsu nepārtrauktās integrācijas konveijers saskārās ar nopietnām grūtībām. Galvenais zars biežāk bija sarkans nekā zaļš: no 22 pabeigtajiem kvalitātes vārtu izpildes gadījumiem master zarā 10 bija zaļi un 12 sarkani, savukārt vēl 36 izpildes tika atceltas jaunu izmaiņu dēļ. Atsauksmes saņemšana prasīja no 47 līdz 61 minūtei par katru iesniegumu, un tīmekļa saskarnes izvietošana dev un prd vidēs apstājās uz aptuveni divām stundām. Būtiski, ka lielāko daļu kļūmju izraisīja nestabili testi un resursu sacensības, nevis paša produkta defekti.

Kad galvenais zars sabrūk, cieš visas aktīvās darba līnijas flotē. Jaunu izmaiņu iesniegšana sarkanā zarā traucē izstrādātājiem un vairo kļūdas. Projekta īpašnieks pieņēma lēmumu apturēt jaunu funkciju ieviešanu un provizorisko refaktorēšanu, līdz integrācija kļūs stabila un ātra. Tas nozīmēja lēnāku rītu apmaiņā pret daudz ātrākām un uzticamākām dienām nākotnē.

Mēs pievērsāmies patiesajiem šķēršļiem. Pirmkārt, pāreja uz GitHub pārvaldītajiem izpildītājiem saīsināja pilno izpildes laiku no aptuveni 50 minūtēm līdz 30.4 minūšu mediānai (n=12), samazinot rindu gaidīšanas laiku no 19 minūtēm līdz mazāk nekā 0.1 minūtei. Otrkārt, kvalitātes vārti tika atjaunināti, lai pārbaudītu tikai tās daļas, kuras ietekmē konkrētais iesniegums, balstoties uz katra uzdevuma pēdējo sekmīgo izpildi, nevis akli atkārtojot visu. Treškārt, ātras vietējās pārbaudes pirms koda nosūtīšanas dažu sekunžu laikā atklāja vienkāršus defektus. Pēc izpildītāju maiņas sekoja mērķtiecīgi refaktorēšanas posmi (no r8 līdz r14), kas ietaupīja minūtes lēnākajos pārbaudījumos, piemēram, samazinot mobilā pārlūka testu no 164 līdz 63 sekundēm (n=3). Tāpat mainījām kļūdu uzskaiti: vērtējot kļūmes pēc uzdevuma, nevis pēc kopējā izpildījuma, atklājās, ka 42 neveiksmīgus izpildījumus bieži izraisīja tikai seši pamatcēloņi.

Šī pieredze nostiprināja svarīgākās nepārtrauktās integrācijas labās prakses:
1. Vispirms mēriet: fiksējiet reālo gaidīšanas laiku un saskaitiet darbības pirms risinājumu ieviešanas.
2. Pierādiet katru uzlabojumu ar skaitīšanas testu un kontroli, kas izgāžas pie vecās uzvedības.
3. Veiciet ātras pārbaudes lokāli pirms koda nosūtīšanas, lai galvenais zars paliktu tīrs.
4. Saglabājiet apzinātas testu kļūmes un kontroles pagaidu zaros, nekad master zarā.
5. Uztveriet nestabilus testus kā reālus defektus ar augstāko prioritāti.
6. Refaktorējiet nepārtraukti mazos, izmērītos posmos ar skaidru izlases lielumu.
7. Nekavējoties piešķiriet katru bojāto uzdevumu vienam atbildīgajam.

Nepārtrauktās integrācijas sakārtošana tieši paātrina jaunu funkciju piegādi nākotnē. Īsāks atgriezeniskās saites cikls un stabils zaļš zars sniedz ātrumu un pārliecību.
