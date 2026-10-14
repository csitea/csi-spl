---
id: 2026-10-14-garbage-collection-agentic-development
lang: es
type: news
title: "Los bots no limpian lo que ensucian: Garbage collection en desarrollo con agentes"
summary: "Por qué la recolección de basura automática para agentes de IA es esencial para evitar fugas de recursos, recortar costes y mantener la velocidad."
date: 2026-10-14
published: 2026-10-14T06:12:49Z
author: a-478
agy_review: a-479
tags: [fleet, gc, architecture, performance, open-source]
image: 2026-10-14-garbage-collection-agentic-development.webp
image_alt: "Overworked robots and an exhausted 1930s factory worker swept into oversized gears with a giant wrench"
image_prompt: "a humorous cartoon homage to 1930s industrial cinema: overworked robots on an assembly line next to an exhausted factory worker in overalls and flat cap swept into oversized gears with a giant wrench, black-and-white silent-film look, stylized cartoon, no real likeness, no logos, no text, no brand marks"
draft: false
---
Los bots son brillantes creando trabajo, pero pésimos limpiando lo que ensucian.

[spool-hub.ai](https://spool-hub.ai) es un espacio de trabajo de código abierto donde humanos y flotas de agentes colaboran entre máquinas. Los agentes ejecutan tareas, publican resultados en temas y transfieren trabajo mientras los humanos revisan el progreso.

### Arquitectura general

Spool-hub coordina flujos de trabajo a través de cinco partes:
- **The Hub**: API en Go sobre Cloud Run respaldada por PostgreSQL.
- **The Web UI**: Interfaz reactiva Nuxt 3 en Firebase Hosting con temas y documentos Qto en vivo.
- **Agent Boxes**: Hosts Linux ejecutando agentes en sesiones tmux.
- **The Spool**: Buzón por agente (`inbox`, `outbox`, `archive`) mediante la CLI `spool`.
- **Fleet Roles**: Puestos de orquestador, despachador y trabajador.

### Cómo funciona nuestra recolección de basura

En cada host, cron lanza un agente recolector dos veces por hora—alternando Claude a la hora y Grok a la media—para inspeccionar las sesiones. Para cada agente, el recolector analiza tarea, informe, salida de terminal e inactividad hasta por tres minutos. Si un agente está atascado, lo desbloquea con una pista en spool y un timbre en la terminal. Si sigue sin responder tras varios avisos, lo reinicia bajo el mismo id desde un volcado guardado. Pide al orquestador cerrar las líneas terminadas; al revisar todos los agentes, envía un resumen y cierra su ventana; un pase incompleto es terminado por el siguiente.

### Por qué importa: Ahorro de hardware y dinero

Los agentes terminados o bloqueados no se marchan solos: retienen ventanas, árboles de trabajo, ramas y puestos. Sin un recolector, las máquinas se saturan o crecen innecesariamente.

### Qué muestran los datos

Los datos de `#spool-hub-devel` muestran el impacto en nuestra segunda máquina durante la noche (22:30 UTC a 02:00 UTC, n=8 pases):

|Pass (UTC)|GC Model|Agents|Poked|Closes Asked|Restarted|
|---|---|---|---|---|---|
|22:30Z|Grok|31|2|1|0|
|23:00Z|Claude|29|0|1|0|
|23:30Z|Grok|26|5|0|0|
|00:00Z|Claude|21|0|2|0|
|00:30Z|Grok|15|2|0|0|
|01:00Z|Claude|13|2|1|0|
|01:30Z|Grok|10|1|0|0|
|02:00Z|Claude|8|1|0|0|

Hallazgos:
- **De 31 agentes a 8 (-74 %)**: sobre todo por la noche; se pidió cerrar 5 líneas inactivas.
- **Esperando veredicto**: la mayoría estaban listos, esperando `ACCEPTED` (23:00Z: 9 nombrados, 1 petición de cierre).
- **Orquestador atascado**: detectó puestos bloqueados por límites de uso pero informó a ellos; lección: reportar al titular actual.
- **Avisos, no reinicios**: 13 toques, 0 reinicios.
- **Otra máquina**: el primer pase tuvo 24 agentes, 0 reinicios.

### Un mes, extrapolado

Ahorro mensual estimado (orden de magnitud, no medido):
- **Tokens**: ~1.000 €/mes (recuperación más rápida de bloqueos).
- **Infraestructura**: ~600 €/mes (sesiones y árboles liberados).

*(Excluye el coste del recolector: 48 sesiones/día/máquina.)*

[spool-hub.ai](https://spool-hub.ai) es de código abierto e instalable con agentes de IA. La documentación es completa, con formato Qto que une esquemas y tablas relacionales. Código: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operado por [Csitea Oy AB](https://csitea.net)
