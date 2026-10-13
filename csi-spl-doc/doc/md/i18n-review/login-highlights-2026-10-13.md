# Review: auth.login.highlights Chips in 19 Locales (2026-10-13)

**Task**: Language review of the 4 sign-in chips `auth.login.highlights.*` across 19 locales (SPL-1741, brief `9e5533ec-f551-42e5-a6ec-8eac2fae2026.md`, for c-451's SPL-1722).  
**Reviewer**: Antigravity (`a-964@sat`).  
**Source**: English (`en`).

## 1. Corrected Highlights Table

| locale | agents | topics | terminal | open |
|---|---|---|---|---|
| bg | Агенти с име и присъствие | Канали, теми и лични съобщения | Агентите се присъединяват от терминала | Отворен код |
| el | Πράκτορες με όνομα και παρουσία | Κανάλια, θέματα και άμεσα μηνύματα | Οι πράκτορες συνδέονται από το τερματικό | Ανοιχτός κώδικας |
| en | Agents with a name and presence | Channels, topics and DMs | Agents join from the terminal | Open source |
| es | Agentes con nombre y presencia | Canales, temas y mensajes directos | Los agentes se unen desde la terminal | Código abierto |
| et | Agendid nime ja kohalolekuga | Kanalid, teemad ja otsesõnumid | Agendid liituvad terminalist | Avatud lähtekood |
| fi | Agenteilla on nimi ja läsnäolo | Kanavat, aiheet ja yksityisviestit | Agentit liittyvät päätteestä | Avoin lähdekoodi |
| he | סוכנים עם שם ונוכחות | ערוצים, נושאים והודעות ישירות | הסוכנים מצטרפים מהמסוף | קוד פתוח |
| lt | Agentai su vardu ir buvimu | Kanalai, temos ir tiesioginės žinutės | Agentai prisijungia iš terminalo | Atvirasis kodas |
| lv | Aģenti ar vārdu un klātbūtni | Kanāli, tēmas un tiešās ziņas | Aģenti pievienojas no termināļa | Atvērtais kods |
| mk | Агенти со име и присуство | Канали, теми и директни пораки | Агентите се приклучуваат од терминалот | Отворен код |
| nl | Agents met een naam en aanwezigheid | Kanalen, onderwerpen en directe berichten | Agents doen mee vanuit de terminal | Open source |
| pl | Agenci z imieniem i obecnością | Kanały, tematy i wiadomości bezpośrednie | Agenci dołączają z terminala | Otwarte źródło |
| ro | Agenți cu nume și prezență | Canale, teme și mesaje directe | Agenții se alătură din terminal | Cod sursă deschis |
| ru | Агенты с именем и присутствием | Каналы, темы и личные сообщения | Агенты подключаются из терминала | Открытый исходный код |
| sk | Agenti s menom a prítomnosťou | Kanály, témy a priame správy | Agenti sa pripájajú z terminálu | Otvorený zdrojový kód |
| sr | Агенти са именом и присуством | Канали, теме и директне поруке | Агенти се придружују из терминала | Отворени код |
| sv | Agenter med namn och närvaro | Kanaler, ämnen och direktmeddelanden | Agenter ansluter från terminalen | Öppen källkod |
| tr | Adı ve varlığı olan ajanlar | Kanallar, konular ve doğrudan mesajlar | Ajanlar terminalden katılır | Açık kaynak |
| uk | Агенти з іменем і присутністю | Канали, теми та особисті повідомлення | Агенти приєднуються з термінала | Відкритий код |

## 2. Review Notes and Rationale

- **bg**: `terminal` changed from `Агентите влизат от терминала` to `Агентите се присъединяват от терминала` to match `auth.login.about` ("вашите агенти се присъединяват от своя терминал") and accurately translate "join" rather than "log in / enter".
- **el**: `topics` changed from `Κανάλια, θέματα και προσωπικά μηνύματα` to `Κανάλια, θέματα και άμεσα μηνύματα` to match `sidebar.direct_messages` and `auth.login.about` ("άμεσα μηνύματα" is the established term for DMs across the locale).
- **en**: Unchanged (source locale).
- **es**: `terminal` changed from `Los agentes entran desde la terminal` to `Los agentes se unen desde la terminal` to match `auth.login.about` ("tus agentes se unen desde su terminal") and natural Spanish for joining a workspace.
- **et**: Unchanged (`et.json` terms for agents, topics, terminal, and open source match `auth.login.about` and `logo.about` perfectly).
- **fi**: Unchanged (`fi.json` terms and natural phrasing match `auth.login.about`, `sidebar.direct_messages`, and `logo.about`).
- **he**: `terminal` changed from `הסוכנים מצטרפים מהטרמינל` to `הסוכנים מצטרפים מהמסוף` to match `auth.login.about` ("הסוכנים שלכם מצטרפים מהמסוף שלהם") and standard onboarding terminology in `he.json`.
- **lt**: `topics` changed from `Kanalai, temos ir asmeninės žinutės` to `Kanalai, temos ir tiesioginės žinutės` to match `sidebar.direct_messages` and `auth.login.about` ("tiesioginės žinutės" is the established term for DMs).
- **lv**: Unchanged (`lv.json` terms match `auth.login.about`, `sidebar.direct_messages`, and `logo.about`).
- **mk**: Unchanged (`mk.json` terms match `auth.login.about`, `sidebar.direct_messages`, and `logo.about`).
- **nl**: `topics` changed from `Kanalen, onderwerpen en privéberichten` to `Kanalen, onderwerpen en directe berichten` to match `sidebar.direct_messages` and `auth.login.about` ("directe berichten" is the established term for DMs; "privéberichten" is unused).
- **pl**: `agents` changed from `Agenci z nazwą i obecnością` to `Agenci z imieniem i obecnością` because agents are teammates with personal names ("imię"), matching `auth.login.about` ("każdy agent ma własne imię i obecność"); `topics` changed from `Kanały, wątki i wiadomości prywatne` to `Kanały, tematy i wiadomości bezpośrednie` to match `nav.topics` ("Tematy", distinct from threads "wątki") and `sidebar.direct_messages` ("Wiadomości bezpośrednie").
- **ro**: `topics` changed from `Canale, subiecte și mesaje directe` to `Canale, teme și mesaje directe` to match `auth.login.about` ("canale, teme și mesaje directe") and `nav.topics` ("Teme").
- **ru**: Unchanged (`ru.json` terms match `auth.login.about`, `sidebar.direct_messages`, and `logo.about`).
- **sk**: Unchanged (`sk.json` terms match `auth.login.about`, `sidebar.direct_messages`, and `logo.about`).
- **sr**: `terminal` changed from `Агенти се прикључују из терминала` to `Агенти се придружују из терминала` to match `auth.login.about` ("ваши агенти се придружују из свог терминала") and accurately translate "join" rather than "connect / plug in".
- **sv**: Unchanged (`sv.json` terms match `auth.login.about`, `sidebar.direct_messages`, and `logo.about`).
- **tr**: Unchanged (`tr.json` terms match `auth.login.about`, `sidebar.direct_messages`, and `logo.about`).
- **uk**: Unchanged (`uk.json` terms match `auth.login.about`, `sidebar.direct_messages`, and `logo.about`).
