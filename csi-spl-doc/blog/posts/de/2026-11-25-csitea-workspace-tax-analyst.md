---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: de
type: news
title: "Schlechter Unternehmer, guter Steueranalyst: Ein privater Spool-Hub-Workspace hat die Steuern meiner Firma erledigt"
summary: "Ich behalte die Steuern meiner Firma nicht im Blick. Ein privater Spool-Hub-Workspace und ein Agent ordneten ein Jahr Vero.fi-Dokumente in rund drei Stunden."
date: 2026-11-25
published: 2026-11-25T13:55:48Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Eine Infografik: ein Unternehmer mit Stapeln von Steuerpapieren, ein Roboter als Steueranalyst, in der Mitte ein privater Spool-Hub-Workspace, ein Agent, der Vero.fi per MCP im Browser öffnet, Dokumente in Ordnern nach Jahr, Steuer und Zahlungen auf dem Cloud-Laufwerk, eine E-Mail an den Buchhalter und die Zeiten: von Hand 5-7 Stunden, Einrichtung und Automatisierung 3 Stunden, nächstes Mal 15 Minuten."
image_prompt: "the owner's own infographic (made with Gemini), published as-is; centre-cropped to 16:9 by the blog encoder"
---
Zugegeben: Ich bin ein schlechter Unternehmer. Bei den Steuern meiner Firma verliere ich den Überblick. Disziplin und Automatisierung habe ich oft versucht; es hat nie gehalten.

Alles an einem Ort zu sehen, ließ mich grübeln: Meine Firma zahlt wohl zu viel Steuern. Auf LinkedIn: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

Als Nächstes: Automatisierung, Skripte plus Zeitplanung und Infrastruktur von Spool-Hub, damit der wöchentliche Check von selbst läuft. Die Skripte sind öffentlich: [github.com/csitea/csi-tax](https://github.com/csitea/csi-tax).

## 1. 🖥️ Mein Rechner, gesteuert aus dem Browser

Lassen Sie einen Agenten auf Ihrem Laptop oder Desktop laufen und steuern Sie ihn über die Spool-Hub-Weboberfläche. Mit MCP und Firefox (oder einem anderen MCP-Browser) holt er Informationen aus jedem System, auf das Sie Zugriff haben. Hier: Vero.fi, der Online-Dienst der finnischen Steuerverwaltung (vero = Steuer).

## 2. 📂 Was passiert ist

Im privaten Workspace meiner Firma fragte ich nach der Steuervorauszahlung und ließ den Agenten einen Browser auf meinem Desktop öffnen.

- Ich meldete mich selbst an; der Agent tippt, liest oder speichert nie Zugangsdaten.
- Er holte Bescheide, Schreiben und Zahlungsdaten des Jahres und legte sie samt älteren Steuerunterlagen auf dem Cloud-Laufwerk nach Monat und Typ ab.
- Ich bat um ein Issue pro Thema; die Agenten schrieben eine begründete E-Mail an den Buchhalter.
- Ich steuerte mit kurzen Nachrichten; die Dokumente blieben privat.

## 3. ⏱️ Vorher und nachher

Von Hand hat es 5-7 Stunden gedauert.

Jetzt: 96 kurze Nachrichten, etwa sechs Anmeldungen und rund 3 Stunden, in denen die Automatisierung und die Einrichtung entstanden sind (UTC, 24.11.2026):

| Phase | Zeit |
|---|---|
| erste Frage | 14.23 |
| Agentenanfrage, Anmeldung | 14.59-15.12 |
| eigenes Repository, Abruf | 15.56-17.22 |
| 30/32 Dokumente auf dem Laufwerk | 17.45 |
| E-Mail fertig | 18.10 |

Ab jetzt sollte derselbe Steuerdurchlauf weniger als 15 Minuten pro Woche dauern.

## 4. 📅 Der Wochenbericht

Ich bat um einen wöchentlichen Bericht: neue Dokumente, Fristen, offene Fragen. Der Code ist fertig, aber noch nicht zeitgesteuert.

## 5. 🏢 Csitea Oy

Csitea Oy, ein Beratungsunternehmen, finanziert und entwickelt Spool-Hub. Es bietet Cloud- und DevOps-Beratung (AWS, Google Cloud, Kubernetes, Terraform, Python-Backends) und einen Onlineshop-Service: [csitea.net](https://csitea.net).

## 6. 🔧 Der technische Teil: das Dienstkonto

Auf dem Cloud-Laufwerk arbeitet der Agent als Backup-Dienstkonto der Firma, nicht als ich. Er sieht nur Ordner, die mit ihm geteilt sind: für die Steuern einen Stammordner für alle Finanzunterlagen, in dem der Agent Jahr/Monat/vero/Typ angelegt hat. Der Schlüssel bleibt auf dem Rechner, nicht in git; der Code liest Schlüssel und Ordner aus benannten Variablen.

## 7. 🏭 Open Source

Spool Hub ist Open Source (GNU AGPL v3): Betreiben Sie Ihre eigene Instanz in der Cloud oder mit `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Ein Demo-Konto? Kontakt über [csitea.net](https://csitea.net).
