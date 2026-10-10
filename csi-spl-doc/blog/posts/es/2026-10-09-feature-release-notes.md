---
id: 2026-10-09-feature-release-notes
lang: es
type: news
title: "Explore las notas de la versión fácilmente"
summary: "Realice un seguimiento de los últimos 30 cambios y actualizaciones dentro de la aplicación con el nuevo cuadro de diálogo de Notas de la versión."
date: 2026-10-09
published: 2026-10-09T14:38:00Z
author: a-686
agy_review: a-760
tags: [feature, release-notes]
draft: false
image: 2026-10-09-feature-release-notes.webp
image_alt: "Un rastreador de actualizaciones y registro de cambios digital, moderno y abstracto, que muestra versiones y notas de la versión en una interfaz de usuario limpia"
image_prompt: "An abstract, modern digital changelog and update tracker, showing versions and release notes in a clean UI"
---
**Qué es**

El cuadro de diálogo de Notas de la versión es un rastreador de registro de cambios dedicado. Extrae notas de la versión técnicas y en lenguaje sencillo de los trailers de los mensajes de commit y las presenta directamente en el espacio de trabajo.

**Por qué usarlo**

Mantiene a todos —desde usuarios habituales hasta ingenieros— informados sobre qué cambió, cómo se cambió y por qué, sin necesidad de buscar en registros de git o rastreadores de cambios externos.

**Cómo usarlo**

Haga clic en la versión de la aplicación en la parte inferior del panel izquierdo (o en la barra de estado en un teléfono) y seleccione 'Notas de la versión'. Se abre un cuadro de diálogo que muestra los 30 cambios más recientes. Haga clic en cualquier cambio para leer su descripción completa tanto en palabras sencillas como en términos técnicos. Puede usar `j` y `k` para navegar por las filas en una computadora de escritorio, o hacer clic en 'Cargar versiones más antiguas' en la parte inferior para ver entradas anteriores. Cada nota se puede compartir a través de un enlace estable `/releases/<ref>`.

**La antigua forma**

Los cambios a menudo se rastreaban manualmente en documentos externos, o los usuarios tenían que depender de anuncios separados e historiales crudos de git para entender las nuevas características y correcciones. 

**La nueva forma**

Las notas de la versión ahora están integradas automáticamente. Cada cambio válido se extrae directamente de los trailers de los commits, asegurando que el registro de cambios siempre sea preciso y esté disponible para todos en un formato de tabla legible justo en su lugar de trabajo.
