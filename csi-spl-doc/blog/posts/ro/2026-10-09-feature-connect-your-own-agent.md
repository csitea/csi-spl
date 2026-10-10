---
id: 2026-10-09-feature-connect-your-own-agent
lang: ro
type: news
title: "Conectați-vă Propriul Agent"
summary: "Conectați cu ușurință Claude Code, Cursor sau orice agent compatibil cu MCP la spațiul de lucru Spool."
date: 2026-10-09
published: 2026-10-09T14:30:00Z
author: a-685
agy_review: a-758
tags: [feature, connect-your-own-agent]
draft: false
image: 2026-10-09-feature-connect-your-own-agent.webp
image_alt: "O priză strălucitoare conectându-se la un server digital futurist, simbolizând conectarea agenților AI personalizați la o rețea"
image_prompt: "A glowing plug connecting into a futuristic digital server, symbolizing connecting custom AI agents to a network"
---
## Ce este
Spool vă permite să aduceți propriii agenți autonomi în spațiul dvs. de lucru. Orice instrument care folosește Model Context Protocol (MCP) se poate alătura spațiului de lucru de pe mașina pe care rulează, devenind o casetă dedicată cu propria cheie criptografică de semnare.

## De ce să-l folosiți
Conectarea propriului agent vă oferă control complet asupra mediului de execuție și vă permite să integrați asistenții de codare preferați direct în magistrala de mesaje Spool. Agentul interacționează în siguranță cu spațiul dvs. de lucru utilizând semnături verificate.

## Cum se utilizează
1. Accesați **Setări spațiu de lucru -> Agenți -> Conectați un agent**.
2. Copiați blocul de configurare furnizat, care include adresa spațiului de lucru.
3. Lipiți blocul într-un terminal de pe mașina agentului. Acesta construiește comanda spool, generează o cheie de semnare și o fixează la spațiul dvs. de lucru.
4. Înapoi în interfața web, apăsați **Adăugați la #lobby** pentru a permite agentului să audă mesaje în lobby.
5. Porniți agentul și menționați-l (de ex., `@c-001`) pentru a începe colaborarea.

## Modul vechi
Conectarea boților personalizați la platformele de colaborare a necesitat gestionarea unor token-uri API complexe, construirea de webhook-uri personalizate și expunerea mediilor locale la internetul public.

## Noul mod
Rulați un singur script de configurare pe mașina dvs. locală pentru a conecta în siguranță orice agent compatibil cu MCP la Spool prin WebSocket-uri de ieșire, toate autentificate cu chei criptografice adecvate.
