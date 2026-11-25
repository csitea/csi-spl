---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: sv
type: news
title: "En dålig företagare, en bra skatteanalytiker: en privat Spool-Hub-arbetsyta skötte mitt företags skatter"
summary: "Jag hänger inte med i mitt företags skatter. En privat Spool-Hub-arbetsyta och en agent ordnade ett års dokument från Vero.fi på ungefär tre timmar."
date: 2026-11-25
published: 2026-11-25T13:55:48Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Ett terminalfönster där en agent letar efter skattefiler på företagets molnlagring; tjänstekontots namn, sökvägar, id:n och mappnamn är dolda under svarta rutor."
image_prompt: "a screenshot of the agent's terminal and its side panel on a desktop, private details covered with solid black boxes, cropped to 16:9; not generated"
---
Jag erkänner: jag är en dålig företagare. Jag hänger inte med i mitt företags skatter. Jag har försökt med disciplin och automation många gånger; det har aldrig fastnat.

När jag såg allt på ett ställe slog det mig: jag betalar nog för mycket skatt för mitt företag. På LinkedIn: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

## 1. 🖥️ Min dator, styrd från webbläsaren

Kör en agent på din egen bärbara eller stationära dator och styr den från Spool-Hubs webbgränssnitt. Med MCP och Firefox (eller valfri MCP-webbläsare) hämtar den information från alla system du har åtkomst till. Här: Vero.fi, finska Skatteförvaltningens e-tjänst (vero = skatt).

## 2. 📂 Vad som hände

I mitt företags privata arbetsyta frågade jag om förskottsskatten och lät sedan agenten öppna en webbläsare på min dator.

- Jag loggade in själv; agenten skriver, läser eller sparar aldrig inloggningsuppgifter.
- Den hämtade årets beslut, brev och betalningsuppgifter och arkiverade dem, och de äldre skattedokumenten, på molnlagringen per månad och typ.
- Jag bad om ett ärende per tema; agenterna skrev ett motiverat mejl till bokföraren.
- Jag styrde med korta meddelanden; dokumenten förblev privata.

## 3. ⏱️ Före och efter

För hand, min uppskattning (inte mätt): 5-7 timmar. Cirka 30 dokument arkiverade (3-5 min styck), betalningar och förfallodagar (1-2 h), gamla filer (1 h), mejlet (1 h).

Nu: 96 korta meddelanden, ungefär sex inloggningar, ungefär 3 timmars uppsättning (UTC, 24.11.2026):

| fas | tid |
|---|---|
| första frågan | 14.23 |
| agentbegäran, inloggning | 14.59-15.12 |
| eget repo, hämtning | 15.56-17.22 |
| 30/32 dokument på enheten | 17.45 |
| mejlet klart | 18.10 |

Från begäran till klart: 2 h 46 min; från fråga till mejl: 3 h 47 min.

## 4. 📅 Veckorapporten

Jag bad om en veckorapport: nya dokument, förfallodagar, öppna frågor. Koden är klar men ännu inte schemalagd.

## 5. 🏢 Csitea Oy

Csitea Oy, ett konsultföretag, finansierar och utvecklar Spool-Hub. Det erbjuder moln- och DevOps-konsulting (AWS, Google Cloud, Kubernetes, Terraform, Python-backends) och en e-handelstjänst: [csitea.net](https://csitea.net).

## 6. 🔧 Den tekniska delen: tjänstekontot

På molnlagringen arbetar agenten som företagets tjänstekonto för säkerhetskopiering, inte som jag. Den ser bara mappar som delats med den: för skatterna en rotmapp för alla ekonomiska dokument, där agenten byggde år/månad/vero/typ. Nyckeln stannar på datorn, inte i git; koden läser nyckel och mapp från namngivna variabler.

## 7. 🏭 Öppen källkod

Spool Hub är öppen källkod (GNU AGPL v3): kör din egen instans i molnet eller med `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Vill du ha ett demokonto? Kontakta [csitea.net](https://csitea.net).
