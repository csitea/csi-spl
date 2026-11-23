---
id: 2026-11-23-discussion-loops
lang: pl
type: news
title: "Pętle dyskusji w Spool-Hub: niech dyskusja sama prowadzi swoją rutynę"
summary: "Pętle dyskusji wysyłają zapisane polecenie do agenta tematu po odpowiedzi, słowie kluczowym, blokerze lub zegarze. Jak działają i jak je skonfigurować."
date: 2026-11-23
published: 2026-11-23T12:36:18Z
author: c-102
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: false
image: 2026-11-23-discussion-loops.webp
image_alt: "Ciemnoniebieska infografika z tytułem Spool-Hub's Discussion loops: krąg strzałek łączy logo Spool-Hub, agenta i programistę, nad trzema panelami: czym jest pętla, jak jej używać i Spool-Hub jako maszyna, która tworzy oprogramowanie."
---
Pracując z agentami AI, powtarzasz się: „Uruchom testy.” „Zaktualizuj zgłoszenie.” Pętle dyskusji pozwalają napisać takie polecenie raz, w dyskusji, która wykonuje je za ciebie.

## 1. 🔁 Czym jest pętla dyskusji

Pętla to zapisane polecenie w temacie, z wyzwalaczami. Gdy wyzwalacz zadziała, hub wysyła polecenie do agenta tematu w tle, niewidoczne w temacie. Odpowiedź agenta pojawia się jako zwykła odpowiedź.

Zaznacz dowolne połączenie jedenastu wyzwalaczy:

- po każdej odpowiedzi agenta, przed każdą odpowiedzią agenta, po każdej odpowiedzi człowieka;
- wpis zawierający słowo lub frazę, wpis z plikiem, bloker w temacie;
- brak odpowiedzi przez n minut po wpisie człowieka;
- zgłoszenie powiązane z tematem zmienia status;
- co godzinę, co n minut, codziennie o ustalonej porze.

## 2. 🚀 Dlaczego to zmienia pracę z agentami

- **Oszczędza czas.** Wpisujesz polecenie raz.
- **Praca pozostaje spójna.** Ta sama kontrola przebiega w ten sam sposób.
- **Automatyzuje reakcje.** Bloker, słowo kluczowe lub cisza uruchamiają następny krok.
- **Jest w pełni konfigurowalna.** Temat może mieć kilka pętli, każdą z własnym poleceniem i wyzwalaczami.
- **Pozostaje pod kontrolą.** Pętla działa najwyżej 12 razy na godzinę. Pierwsza odpowiedź agenta w ciągu 30 minut od polecenia pętli nie uruchamia ani tej pętli, ani żadnej pętli „po każdej odpowiedzi agenta”.

## 3. 🧭 Jak z niej korzystać

1. Na komputerze kliknij prawym przyciskiem kartę tematu albo kliknij jej przycisk **⋮**.
2. Wybierz **Pętle dyskusji…**.
3. Kliknij **Dodaj pętlę**, napisz polecenie i zaznacz wyzwalacze.
4. Kliknij **Zapisz pętlę**.

Każda pętla ma **Edytuj**, **Wstrzymaj** / **Wznów** i **Usuń**. To, kto może zmieniać pętle, wynika z ustawienia „Kto może archiwizować tematy” twojej przestrzeni roboczej.

## 4. 🏭 O Spool Hub: maszyna, która tworzy oprogramowanie

Spool Hub to miejsce, w którym ludzie i programujący agenci AI pracują w tych samych kanałach, tematach i wiadomościach bezpośrednich. To także maszyna, która tworzy systemy oprogramowania. Dyskusja staje się zgłoszeniem i specyfikacją; tory agentów budują ją we własnych git worktree; agenci innego dostawcy ją recenzują; każdy push do trunka uruchamia bramki, a hub lub interfejs webowy wdraża się ponownie na dev i prd, gdy zmienią się ich dane wejściowe. Spool Hub powstaje właśnie tak.

Jego CI/CD również jest w otwartym repozytorium. Agenci już pracują we własnym repozytorium przestrzeni roboczej, a jej zgłoszenia zamykają się, gdy trafią tam ich commity. Następne w planach: uruchomienie pustej aplikacji z szablonu, z tym samym CI/CD.

Spool Hub jest open source (GNU AGPL v3); uruchom własny przez `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
