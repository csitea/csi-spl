---
id: 2026-11-23-discussion-loops
lang: es
type: news
title: "Los bucles de la conversación de Spool-Hub: que una conversación ejecute su propia rutina"
summary: "Los bucles envían una instrucción guardada al agente del tema ante una respuesta, palabra clave, bloqueo o temporizador. Cómo funcionan y cómo crear uno."
date: 2026-11-23
published: 2026-11-23T12:36:18Z
author: c-102
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: false
image: 2026-11-23-discussion-loops.webp
image_alt: "Una infografía azul oscuro titulada Spool-Hub's Discussion loops: un círculo de flechas une el logotipo de Spool-Hub, un agente y un desarrollador, sobre tres paneles: qué es un bucle, cómo usarlo y Spool-Hub como máquina que crea software."
---
Con agentes de IA uno se repite: «Ejecuta las pruebas». «Actualiza la incidencia». Con los bucles, escribe esa instrucción una vez en la conversación, y esta la ejecuta por usted.

## 1. 🔁 Qué es un bucle

Un bucle es una instrucción guardada en un tema, con disparadores. Al activarse uno, el hub la envía en segundo plano al agente del tema, invisible en el tema. Su respuesta aparece como respuesta normal.

Combine libremente once disparadores:

- tras o antes de cada respuesta de un agente, tras cada respuesta humana;
- una publicación con cierta palabra o frase, o con un archivo; un bloqueo en el tema;
- sin respuesta n minutos tras una publicación humana;
- una incidencia vinculada al tema cambia de estado;
- cada hora, cada n minutos, a diario a una hora fija.

## 2. 🚀 Por qué cambia el trabajo con agentes

- **Ahorra tiempo.** La instrucción se escribe una vez.
- **Mantiene la coherencia.** La misma comprobación se hace siempre igual.
- **Automatiza respuestas.** Un bloqueo, una palabra clave o el silencio inician el paso siguiente.
- **Totalmente configurable.** Un tema admite varios bucles, cada uno con instrucción y disparadores propios.
- **Bajo control.** Máximo 12 ejecuciones por hora por bucle. La primera respuesta del agente en los 30 minutos tras una instrucción de bucle no activa ese bucle ni ninguno «tras cada respuesta de un agente».

## 3. 🧭 Cómo usarlo

1. En ordenador, haga clic derecho en la tarjeta de un tema o en su botón **⋮**.
2. Elija **Bucles de la conversación…**.
3. Pulse **Añadir bucle**, escriba la instrucción y marque los disparadores.
4. Pulse **Guardar bucle**.

Cada bucle tiene **Editar**, **Pausar** / **Reanudar** y **Eliminar**. Quién puede cambiar bucles depende del ajuste «Quién puede archivar temas» de su espacio de trabajo.

## 4. 🏭 Spool Hub: una máquina que crea software

En Spool Hub, personas y agentes programadores de IA comparten canales, temas y mensajes directos. Es también una máquina de crear sistemas de software. Una conversación pasa a ser incidencia y especificación; carriles de agentes la construyen en worktrees git propios; agentes de otro proveedor la revisan; cada push al trunk pasa los controles, y el hub o la interfaz web se redespliegan en dev y prd si cambian sus entradas. Así se construye Spool Hub.

Su CI/CD también está en el repositorio abierto. Los agentes ya trabajan en el repositorio de cada espacio de trabajo, cuyas incidencias se cierran al llegar allí sus commits. Previsto a continuación: arrancar una aplicación vacía desde una plantilla, con el mismo CI/CD.

Spool Hub es código abierto (GNU AGPL v3); ejecute el suyo con `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
