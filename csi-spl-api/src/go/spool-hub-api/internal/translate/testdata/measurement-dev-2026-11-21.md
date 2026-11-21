# Google Cloud Translation v3 on dev: the measurement of spec 123 16.6.7 row L3

Spec 123 section 16.6.3 left two things believed, not checked: that the API
takes all 19 locales of the hub (`he`, `mk` and `sr` included) and that the
no-translate span of section 16.6.5 keeps a mask token intact. Row L3's first
commit measures both on dev.

- **Run:** 2026-11-21, tree `1c7237836` (origin/master), `measure-dev.py` in this
  directory, against `translation.googleapis.com/v3/projects/csi-spl-dev/locations/global:translateText`
  as the dev project service account (its key, a throwaway `CLOUDSDK_CONFIG`),
  `mimeType: text/html`, source `en`, each token wrapped
  `<span translate="no">[NAME_1]</span>`, the 18 targets of a text in parallel.
- **n:** 20 synthetic texts x 18 locales = 360 calls. No person, workspace or
  estate text: every name is already a token.
- **Version:** the v3 REST API as served that day; the hub's runtime SA was
  not the caller (the hub has no client yet), the dev project SA was.

## Result

n = 20 texts x 18 locales = 360 calls, 13158 characters sent
per call latency s: p50 0.56, p95 5.32, max 5.74
per text wall (18 in parallel) s: p50 0.69, max 5.75

| locale | answered | span kept | tokens intact, no span left | equal to English |
|---|---|---|---|---|
| bg | 20/20 | 20/20 | 20/20 | 0/20 |
| fi | 20/20 | 20/20 | 20/20 | 1/20 |
| ru | 20/20 | 20/20 | 20/20 | 0/20 |
| sv | 20/20 | 20/20 | 20/20 | 1/20 |
| he | 20/20 | 20/20 | 20/20 | 0/20 |
| tr | 20/20 | 20/20 | 20/20 | 1/20 |
| mk | 20/20 | 20/20 | 20/20 | 0/20 |
| el | 20/20 | 20/20 | 20/20 | 0/20 |
| lt | 20/20 | 20/20 | 20/20 | 0/20 |
| et | 20/20 | 20/20 | 20/20 | 0/20 |
| lv | 20/20 | 20/20 | 20/20 | 0/20 |
| sr | 20/20 | 20/20 | 20/20 | 0/20 |
| ro | 20/20 | 20/20 | 20/20 | 0/20 |
| uk | 20/20 | 20/20 | 20/20 | 0/20 |
| sk | 20/20 | 20/20 | 20/20 | 0/20 |
| pl | 20/20 | 20/20 | 20/20 | 0/20 |
| es | 20/20 | 20/20 | 20/20 | 0/20 |
| nl | 20/20 | 20/20 | 20/20 | 1/20 |

sample, text 1 ('Monthly salary of [NAME_1]'):
- bg: Месечна заплата на [NAME_1]
- fi: [NAME_1] :n kuukausipalkka
- ru: Ежемесячная зарплата [NAME_1]
- sv: Månadslön för [NAME_1]
- he: משכורת חודשית של [NAME_1]
- tr: [NAME_1] 'in aylık maaşı
- mk: Месечна плата на [NAME_1]
- el: Μηνιαίος μισθός του/της [NAME_1]
- lt: [NAME_1] mėnesinis atlyginimas
- et: [NAME_1] kuupalk
- lv: Lietotāja [NAME_1] mēneša alga
- sr: Месечна плата [NAME_1]
- ro: Salariul lunar al lui [NAME_1]
- uk: Щомісячна зарплата [NAME_1]
- sk: Mesačný plat [NAME_1]
- pl: Miesięczna pensja [NAME_1]
- es: Salario mensual de [NAME_1]
- nl: Maandelijks salaris van [NAME_1]

## What it means for the hub

- All 18 targets answered 20 of 20, `he`, `mk` and `sr` included: no locale
  code mapping is needed for `i18n.Supported`.
- The span came back intact 360 of 360, and every token survived the unmask
  with no `<span` left: the 16.6.5 markup holds on this sample (n = 20 per
  locale is evidence, not proof of absence).
- The answer comes HTML-escaped (`&amp;`, `&lt;`): the client unescapes after
  it strips the spans.
- Four answers equal the English text (`Bonus Q3` in fi, sv, tr and nl): the
  16.6.6 check drops them, so such a text stays missing and the nightly fill
  asks for it again.
- Latency: p95 5.32 s, max 5.74 s per call against the proposed 5 s shared
  deadline (`env.cost.labels_translate_timeout_s`): at 5 s about 1 text in 20
  loses some locales to the night's fill. The hub's default here is 8 s.
- Characters: 13158 sent for 20 texts, about 660 per text with the span
  markup counted (the daily cap counts what is sent).
- Price: not measured here (row L0 records it).
