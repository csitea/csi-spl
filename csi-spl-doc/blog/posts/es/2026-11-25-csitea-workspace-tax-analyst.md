---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: es
type: news
title: "Mal empresario, buen analista fiscal: un espacio de trabajo privado de Spool-Hub se ocupó de los impuestos de mi empresa"
summary: "No sé llevar los impuestos de mi empresa. Un espacio de trabajo privado de Spool-Hub y un agente ordenaron un año de documentos de Vero.fi en unas tres horas."
date: 2026-11-25
published: 2026-11-25T13:55:48Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Una ventana de terminal en la que un agente busca archivos fiscales en la unidad en la nube de la empresa; el nombre de la cuenta de servicio, las rutas, los identificadores y los nombres de carpetas están tapados con recuadros negros."
image_prompt: "a screenshot of the agent's terminal and its side panel on a desktop, private details covered with solid black boxes, cropped to 16:9; not generated"
---
Lo admito: soy un mal empresario. No llevo al día los impuestos de mi empresa. Probé disciplina y automatización muchas veces; nunca duró.

Verlo todo junto me hizo pensar: seguramente pago demasiados impuestos por mi empresa. En LinkedIn: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

## 1. 🖥️ Mi máquina, dirigida desde el navegador

Ejecute un agente en su portátil o sobremesa y diríjalo desde la interfaz web de Spool-Hub. Con MCP y Firefox (o cualquier navegador MCP) obtiene información de cualquier sistema al que tenga acceso. Aquí: Vero.fi, el portal de la Agencia Tributaria finlandesa (vero = impuesto).

## 2. 📂 Qué pasó

En el espacio de trabajo privado de mi empresa pregunté por el impuesto anticipado y pedí al agente abrir un navegador en mi ordenador.

- Inicié sesión yo; el agente nunca escribe, lee ni guarda credenciales.
- Descargó resoluciones, cartas y pagos del año y los archivó, con los documentos fiscales anteriores, en la nube por mes y tipo.
- Pedí una incidencia por tema; los agentes redactaron un correo razonado al contable.
- Dirigí con mensajes breves; los documentos siguieron privados.

## 3. ⏱️ Antes y después

A mano, a mi juicio (sin medir): 5-7 horas. Unos 30 documentos archivados (3-5 min c/u), pagos y vencimientos (1-2 h), archivos antiguos (1 h), el correo (1 h).

Ahora: 96 mensajes breves, unos seis accesos, unas 3 horas de preparación (UTC, 24.11.2026):

| fase | hora |
|---|---|
| primera pregunta | 14.23 |
| solicitud al agente, acceso | 14.59-15.12 |
| repositorio propio, descarga | 15.56-17.22 |
| 30/32 documentos en la nube | 17.45 |
| correo listo | 18.10 |

De la solicitud al final: 2 h 46 min; de la pregunta al correo: 3 h 47 min.

## 4. 📅 El informe semanal

Pedí un informe semanal: documentos nuevos, vencimientos, preguntas abiertas. El código está listo, aún sin programar.

## 5. 🏢 Csitea Oy

Csitea Oy, consultora, financia y desarrolla Spool-Hub. Ofrece consultoría cloud y DevOps (AWS, Google Cloud, Kubernetes, Terraform, backends en Python) y servicio de tienda online: [csitea.net](https://csitea.net).

## 6. 🔧 La parte técnica: la cuenta de servicio

En la nube el agente actúa como la cuenta de servicio de backup de la empresa, no como yo. Solo ve carpetas compartidas con ella: para impuestos, una carpeta raíz de toda la documentación financiera, donde el agente creó año/mes/vero/tipo. La clave queda en la máquina, no en git; el código lee clave y carpeta de variables con nombre.

## 7. 🏭 Código abierto

Spool Hub es código abierto (GNU AGPL v3): ejecute su instancia en la nube o con `docker compose`: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). ¿Cuenta demo? Contacte con [csitea.net](https://csitea.net).
