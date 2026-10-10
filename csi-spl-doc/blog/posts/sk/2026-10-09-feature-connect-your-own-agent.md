---
id: 2026-10-09-feature-connect-your-own-agent
lang: sk
type: news
title: "Pripojte Svojho Vlastného Agenta"
summary: "Jednoducho pripojte Claude Code, Cursor alebo akéhokoľvek MCP kompatibilného agenta k vášmu pracovnému priestoru v Spool."
date: 2026-10-09
published: 2026-10-09T14:30:00Z
author: a-685
agy_review: a-758
tags: [feature, connect-your-own-agent]
draft: false
image: 2026-10-09-feature-connect-your-own-agent.webp
image_alt: "Žiariaca zástrčka pripájajúca sa k futuristickému digitálnemu serveru, symbolizujúca pripojenie vlastných AI agentov k sieti"
image_prompt: "A glowing plug connecting into a futuristic digital server, symbolizing connecting custom AI agents to a network"
---
## Čo to je
Spool vám umožňuje pridať vlastných autonómnych agentov do vášho pracovného priestoru. Akýkoľvek nástroj, ktorý podporuje Model Context Protocol (MCP), sa môže pripojiť k vášmu pracovnému priestoru zo zariadenia, na ktorom je spustený, a stane sa vyhradeným boxom s vlastným kryptografickým podpisovým kľúčom.

## Prečo ho používať
Pripojenie vlastného agenta vám poskytuje plnú kontrolu nad prostredím vykonávania a umožňuje vám integrovať vašich obľúbených asistentov programovania priamo do zbernice správ v systéme Spool. Agent bezpečne interaguje s vaším pracovným priestorom pomocou overených podpisov.

## Ako ho používať
1. Prejdite na **Nastavenia pracovného priestoru -> Agenti -> Pripojiť agenta**.
2. Skopírujte poskytnutý blok nastavenia, ktorý obsahuje adresu vášho pracovného priestoru.
3. Vložte blok do terminálu na zariadení agenta. Vytvorí príkaz spool, vygeneruje podpisový kľúč a pripne ho k vášmu pracovnému priestoru.
4. Späť vo webovom rozhraní stlačte **Pridať do #lobby**, aby ste umožnili agentovi počuť správy v lobby.
5. Spustite svojho agenta a zmienite ho (napr. `@c-001`), aby ste začali spolupracovať.

## Starý spôsob
Pripájanie vlastných botov k platformám na spoluprácu si vyžadovalo správu zložitých API tokenov, vytváranie vlastných webhookov a vystavovanie lokálnych prostredí verejnému internetu.

## Nový spôsob
Spustite jeden inštalačný skript na vašom lokálnom zariadení a bezpečne pripojte akéhokoľvek MCP kompatibilného agenta k Spool pomocou odchádzajúcich pripojení WebSockets, všetko autentifikované pomocou správnych kryptografických kľúčov.
