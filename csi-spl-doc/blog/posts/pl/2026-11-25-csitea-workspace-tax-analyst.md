---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: pl
type: news
title: "Zły przedsiębiorca, dobry analityk podatkowy: prywatna przestrzeń robocza Spool-Hub zajęła się podatkami mojej firmy"
summary: "Nie nadążam z podatkami mojej firmy. Prywatna przestrzeń robocza Spool-Hub i jeden agent uporządkowały roczne dokumenty z Vero.fi w około trzy godziny."
date: 2026-11-25
published: 2026-11-25T13:03:57Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Okno terminala, w którym agent szuka plików podatkowych na dysku chmurowym firmy; nazwa konta usługi, ścieżki, identyfikatory i nazwy folderów są zakryte czarnymi prostokątami."
image_prompt: "a screenshot of the agent's terminal and its side panel on a desktop, private details covered with solid black boxes, cropped to 16:9; not generated"
---
Przyznaję: jestem złym przedsiębiorcą. Nie nadążam z podatkami mojej firmy. Wiele razy próbowałem dyscypliny i automatyzacji; nigdy się nie przyjęło.

Widząc wszystko w jednym miejscu, pomyślałem: pewnie przepłacam podatki mojej firmy. Na LinkedIn: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

## 1. 🖥️ Mój komputer, sterowany z przeglądarki

Uruchom agenta na własnym laptopie lub komputerze stacjonarnym i steruj nim z interfejsu webowego Spool-Hub. Dzięki MCP i Firefox (lub dowolnej przeglądarce MCP) pobiera informacje z każdego systemu, do którego masz dostęp. Tutaj: Vero.fi, e-usługa fińskiej administracji podatkowej (vero = podatek).

## 2. 📂 Co się stało

W prywatnej przestrzeni roboczej mojej firmy zapytałem o zaliczkę na podatek, a potem kazałem agentowi otworzyć przeglądarkę na moim komputerze.

- Zalogowałem się sam; agent nigdy nie wpisuje, nie czyta ani nie przechowuje danych logowania.
- Pobrał decyzje, pisma i dane o płatnościach z danego roku i razem ze starszymi dokumentami podatkowymi ułożył je na dysku chmurowym według miesiąca i typu.
- Poprosiłem o zgłoszenie dla każdego zagadnienia; agenci napisali uzasadniony e-mail do księgowego.
- Sterowałem krótkimi wiadomościami; dokumenty pozostały prywatne.

## 3. ⏱️ Przed i po

Ręcznie, według mojej oceny (bez pomiaru): 5-7 godzin. Uporządkowanie około 30 dokumentów (3-5 min każdy), płatności i terminy (1-2 h), stare pliki (1 h), e-mail (1 h).

Teraz: 96 krótkich wiadomości, około sześciu logowań, około 3 godzin konfiguracji (UTC, 24.11.2026):

| etap | czas |
|---|---|
| pierwsze pytanie | 14.23 |
| prośba do agenta, logowanie | 14.59-15.12 |
| własne repozytorium, pobieranie | 15.56-17.22 |
| 30/32 dokumentów na dysku | 17.45 |
| e-mail gotowy | 18.10 |

Od prośby do końca: 2 h 46 min; od pytania do e-maila: 3 h 47 min.

## 4. 📅 Raport tygodniowy

Poprosiłem o raport tygodniowy: nowe dokumenty, terminy, otwarte pytania. Kod jest gotowy, ale jeszcze nie został zaplanowany.

## 5. 🏢 Csitea Oy

Csitea Oy, firma konsultingowa, finansuje i rozwija Spool-Hub. Oferuje doradztwo w zakresie chmury i DevOps (AWS, Google Cloud, Kubernetes, Terraform, backendy w Pythonie) oraz usługę sklepu internetowego: [csitea.net](https://csitea.net).

## 6. 🔧 Część techniczna: konto usługi

Na dysku chmurowym agent działa jako firmowe konto usługi do kopii zapasowych, a nie jako ja. Widzi tylko udostępnione mu foldery: dla podatków jeden folder główny na wszystkie dokumenty finansowe, w którym agent zbudował rok/miesiąc/vero/typ. Klucz zostaje na komputerze, nie w git; kod czyta klucz i folder z nazwanych zmiennych.

## 7. 🏭 Open source

Spool Hub jest open source (GNU AGPL v3): uruchom własną instancję w chmurze lub przez `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Konto demo? Skontaktuj się: [csitea.net](https://csitea.net).
