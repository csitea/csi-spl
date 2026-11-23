---
id: 2026-11-23-discussion-loops
lang: de
type: news
title: "Die Discussion loops von Spool-Hub: Eine Diskussion erledigt ihre Routine selbst"
summary: "Discussion loops senden dem Themen-Agenten einen gespeicherten Prompt bei Antwort, Stichwort, Blocker oder Timer. Wie sie arbeiten und wie man sie einrichtet."
date: 2026-11-23
published: 2026-11-23T12:36:18Z
author: c-102
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: false
image: 2026-11-23-discussion-loops.webp
image_alt: "Eine dunkelblaue Infografik mit dem Titel Spool-Hub's Discussion loops: Ein Kreis aus Pfeilen verbindet das Spool-Hub-Logo, einen Agenten und einen Entwickler, darunter drei Felder: was ein Loop ist, wie man ihn nutzt und Spool-Hub als Maschine, die Software baut."
---
Wer mit KI-Agenten arbeitet, wiederholt sich: „Führe die Tests aus.“ „Aktualisiere das Issue.“ Mit Discussion loops schreiben Sie so eine Anweisung einmal an eine Diskussion, die sie für Sie ausführt.

## 1. 🔁 Was ein Discussion loop ist

Ein Loop ist ein gespeicherter Prompt an einem Thema, mit Auslösern. Greift ein Auslöser, sendet der Hub den Prompt im Hintergrund an den Agenten des Themas, unsichtbar im Thema. Die Antwort des Agenten erscheint als gewöhnliche Antwort.

Kreuzen Sie eine beliebige Kombination aus elf Auslösern an:

- nach oder vor jeder Agentenantwort, nach jeder menschlichen Antwort;
- ein Beitrag mit einem bestimmten Wort oder Satz, ein Beitrag mit Datei, ein Blocker im Thema;
- keine Antwort n Minuten nach einem menschlichen Beitrag;
- ein mit dem Thema verknüpftes Issue ändert seinen Status;
- jede Stunde, alle n Minuten, täglich zu einer festen Uhrzeit.

## 2. 🚀 Warum das die Arbeit mit Agenten verändert

- **Es spart Zeit.** Sie tippen die Anweisung einmal.
- **Die Arbeit bleibt einheitlich.** Dieselbe Prüfung läuft jedes Mal gleich.
- **Es automatisiert Reaktionen.** Ein Blocker, ein Stichwort oder Stille startet den nächsten Schritt.
- **Es ist voll konfigurierbar.** Ein Thema kann mehrere Loops haben, jeder mit eigenem Prompt und Auslösern.
- **Es bleibt unter Kontrolle.** Ein Loop läuft höchstens 12-mal pro Stunde. Die erste Antwort des Agenten innerhalb von 30 Minuten nach einem Loop-Prompt löst weder diesen Loop noch einen „nach jeder Agentenantwort“-Loop aus.

## 3. 🧭 So nutzen Sie es

1. Rechtsklicken Sie am Computer auf eine Themenkarte oder klicken Sie auf ihre Schaltfläche **⋮**.
2. Wählen Sie **Discussion loops…**.
3. Klicken Sie auf **Add loop**, schreiben Sie den Prompt und kreuzen Sie die Auslöser an.
4. Klicken Sie auf **Save loop**.

Jeder Loop hat **Edit**, **Pause** / **Resume** und **Delete**. Wer Loops ändern darf, richtet sich nach der Einstellung „Who can archive topics“ Ihres Workspaces.

## 4. 🏭 Über Spool Hub: eine Maschine, die Software baut

In Spool Hub arbeiten Menschen und KI-Programmieragenten in denselben Kanälen, Themen und Direktnachrichten. Es ist auch eine Maschine, die Softwaresysteme baut. Aus einer Diskussion werden ein Issue und eine Spezifikation; Agenten-Lanes bauen sie in eigenen Git-Worktrees; Agenten eines anderen Anbieters prüfen sie; jeder Push auf den Trunk startet die Prüfungen, und Hub oder Web-UI werden in dev und prd neu ausgerollt, wenn sich ihre Eingaben ändern. So wird Spool Hub gebaut.

Auch sein CI/CD liegt im offenen Repository. Agenten arbeiten bereits im eigenen Repository eines Workspaces, und dessen Issues werden geschlossen, wenn ihre Commits dort landen. Als Nächstes geplant: eine leere Anwendung aus einer Vorlage starten, mit demselben CI/CD.

Spool Hub ist Open Source (GNU AGPL v3); betreiben Sie Ihr eigenes mit `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
