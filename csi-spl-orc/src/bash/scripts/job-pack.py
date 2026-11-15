#!/usr/bin/env python3
"""job-pack.py - a job-application pack from a vacancy and the master CVs.

SPL-5555: folds the per-pack generators that four dispatch lanes copied and
edited by hand (gen.py, cv.py, why.py, report.py; 4 different gen.py by
md5) into one versioned tool, run by do_job_pack. It holds NO personal
data: the name, the CV text and every per-vacancy word are read at run time
from --master-cv-dir and --content, both outside git. The CONTENT contract:
csi-spl-doc/doc/md/job-pack.md section 3.

Each step runs when its input is given, in this order:
  fetch  --vacancy-url    <out>/vacancy/{vacancy.html,vacancy.txt,contacts.txt}
  pick   --master-cv-dir  <out>/internal/pick.md: per language the base CV
                          whose skills table names the most of the
                          technologies the vacancy names
  build  --content        <out>/out/{<lang>/...,index*.html,<pack>.zip} and
                          <out>/internal/{fit.md,files.md}

Exit: 0 done, 2 a build refusal (a base CV or the CONTENT does not have what
the step needs), 3 the vacancy could not be fetched.
"""

import argparse
import datetime
import hashlib
import html as H
import os
import re
import runpy
import shutil
import subprocess
import sys
import urllib.request
import zipfile

ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "job-pack-assets")
DOCS = {
    "cv": "CV",
    "hl": "Highlights",
    "ppr": "Projects-per-Requirement",
    "rpp": "Requirements-per-Project",
    "why": "Why-Letter",
}
MARKER = ".job-pack"
EMAIL_RX = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
LANG_RX = re.compile(r"(?i)(?:^|[-_.])(en|fi|sv)(?:[-_.]|$)")
REQUIRED = (
    "NAME",
    "ROLE",
    "LANGS",
    "CONTACT",
    "T",
    "L",
    "PR",
    "PROJ_ORDER",
    "REQ",
    "PROJ_HOW",
    "HL",
    "HL_TAIL",
    "IDX",
    "NAMES",
)


class PackError(Exception):
    """A refusal: the input does not have what a step needs."""


class FetchError(Exception):
    """The vacancy could not be read."""


# --- fetch -----------------------------------------------------------------------


def html_text(s):
    s = re.sub(r"(?is)<(script|style|noscript)\b.*?</\1>", " ", s)
    s = re.sub(r"(?i)<br\s*/?>|</(p|div|li|h[1-6]|tr)>", "\n", s)
    s = H.unescape(re.sub(r"<[^>]+>", " ", s))
    lines = (re.sub(r"[ \t\r\f\v]+", " ", x).strip() for x in s.split("\n"))
    return "\n".join(x for x in lines if x)


def fetch(url, out):
    d = os.path.join(out, "vacancy")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (job-pack)"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode(r.headers.get_content_charset() or "utf-8", "replace")
    except (OSError, ValueError) as e:
        raise FetchError(f"cannot fetch the vacancy {url}: {e}") from None
    text = html_text(raw)
    contacts = sorted(set(EMAIL_RX.findall(raw)) | set(EMAIL_RX.findall(text)))
    write(f"{d}/vacancy.html", raw)
    write(f"{d}/vacancy.txt", f"Source: {url}\n\n{text}\n")
    write(f"{d}/contacts.txt", "".join(f"{c}\n" for c in contacts))
    print(
        f"OK fetch: {len(text)} chars of vacancy text, {len(contacts)} contact address(es) -> {d}"
    )
    return text


def vacancy_text(out):
    p = os.path.join(out, "vacancy", "vacancy.txt")
    return read(p) if os.path.isfile(p) else ""


# --- pick ------------------------------------------------------------------------


def cells(row):
    return [
        html_text(c).strip()
        for c in re.findall(r"(?is)<t[dh]\b[^>]*>(.*?)</t[dh]>", row)
    ]


def skills_rows(s):
    """{technology: (level, years, last used)} of a CV's skills table."""
    m = re.search(r"""(?is)<table class=["']skills["'][^>]*>(.*?)</table>""", s)
    rows = {}
    for row in re.findall(r"(?is)<tr\b[^>]*>(.*?)</tr>", m[1] if m else ""):
        c = cells(row)
        if len(c) >= 4 and "<th" not in row.lower():
            rows[c[0]] = (c[1], c[2], c[3])
    return rows


def cv_lang(path, s):
    m = re.search(r"""(?i)<html[^>]*\blang=["']([a-z]{2})""", s)
    if m:
        return m[1].lower()
    m = LANG_RX.search(os.path.basename(path))
    return m[1].lower() if m else ""


def named(tech, text):
    return (
        re.search(r"(?i)(?<![\w])" + re.escape(tech) + r"(?![\w])", text or "")
        is not None
    )


def candidates(master):
    for root, _, fs in sorted(os.walk(master)):
        for n in sorted(fs):
            if n.lower().endswith(".html") and "cv" in n.lower():
                yield os.path.join(root, n)


def pick(master, text, out):
    """Per language, the base CV naming the most of the vacancy's technologies;
    a tie goes to the larger file name (the names carry their date)."""
    best, lines = {}, []
    for p in candidates(master):
        s = read(p)
        lang = cv_lang(p, s)
        hits = [t for t in skills_rows(s) if named(t, text)]
        lines.append((lang, len(hits), p, hits))
        key = (len(hits), os.path.basename(p))
        if lang and (lang not in best or key > best[lang][0]):
            best[lang] = (key, p)
    if not best:
        raise PackError(f"no CV html (a *cv*.html file with a language) under {master}")
    rows = [
        "| lang | score | base CV | vacancy technologies it names |",
        "|:--|--:|:--|:--|",
    ]
    for lang, n, p, hits in sorted(lines, key=lambda x: (x[0], -x[1], x[2])):
        mark = " **picked**" if lang in best and best[lang][1] == p else ""
        rows.append(
            f"| {lang} | {n} | `{os.path.relpath(p, master)}`{mark} | {', '.join(hits)} |"
        )
    write(
        os.path.join(out, "internal", "pick.md"),
        "# Base CV per language\n\n" + "\n".join(rows) + "\n",
    )
    for lang in sorted(best):
        print(
            f"OK pick {lang}: score {best[lang][0][0]} {os.path.relpath(best[lang][1], master)}"
        )
    return {lang: v[1] for lang, v in best.items()}


# --- the pack ----------------------------------------------------------------------


class Pack:
    def __init__(self, c, out, tools):
        self.c, self.out, self.tools = c, out, tools
        self.name = c["NAME"]
        self.slug = re.sub(r"[^A-Za-z0-9]+", "-", self.name).strip("-")
        self.date = c.get("DATE") or datetime.datetime.now(
            datetime.timezone.utc
        ).strftime("%Y-%m-%d")
        self.role = c["ROLE"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", self.role):
            raise PackError(
                f"ROLE {self.role!r} is not a plain name (letters, digits, . _ -): "
                "it names files and dirs under out/"
            )
        self.pack = f"{self.slug}-{self.role}-{self.date}"
        self.letter = c.get("LETTER") or c["W"]
        self.dst = os.path.join(out, "out")
        self.md_dir = os.path.join(out, "internal", "md")

    def files(self, l):
        return {
            k: f"{self.slug}-{v}-{self.role}-{l.upper()}-{self.date}"
            for k, v in DOCS.items()
        }

    # --- the three markdown documents and the index ----------------------------

    def head(self, l):
        t = self.c["T"]
        return (
            f"**{self.name}**\n\n{self.c['CONTACT']} · {t['avail'][l]}\n\n"
            f"**{t['role'][l]} · {t['date'][l]}**\n\n*{t['terms'][l]}*\n\n"
        )

    def md_ppr(self, l):
        L, PR = self.c["L"], self.c["PR"]
        s = (
            f"# {L['ppr'][l]}\n\n"
            + self.head(l)
            + f"*{L['ppr_intro'][l]}*\n\n## {L['summary'][l]}\n\n"
        )
        s += f"| {L['req'][l]} | {L['projs'][l]} |\n|:--|--:|\n"
        for rid, title, rows, _ in self.c["REQ"]:
            s += f"| {rid} {title[l]} | {len({p for p, _ in rows})} |\n"
        for rid, title, rows, note in self.c["REQ"]:
            s += f"\n## {rid} {title[l]}\n\n| {L['proj'][l]} | {L['how'][l]} |\n|:--|:--|\n"
            s += "".join(f"| {PR[p][l]} | {esc(how[l])} |\n" for p, how in rows)
            s += f"\n{note[l]}\n"
        return s

    def md_rpp(self, l):
        L, REQ = self.c["L"], self.c["REQ"]
        legend = " · ".join(f"{rid} {t[l]}" for rid, t, _, _ in REQ)
        s = (
            f"# {L['rpp'][l]}\n\n"
            + self.head(l)
            + f"*{L['rpp_intro'][l]} {L['reqs'][l]}: {legend}.*\n\n"
        )
        s += f"| {L['proj'][l]} | {L['reqs'][l]} | {L['how'][l]} |\n|:--|:--|:--|\n"
        for p in self.c["PROJ_ORDER"]:
            ids = [rid for rid, _, rows, _ in REQ if any(x == p for x, _ in rows)]
            s += f"| {self.c['PR'][p][l]} | {' · '.join(ids)} | {esc(self.c['PROJ_HOW'][p][l])} |\n"
        return s

    def md_hl(self, l):
        s = f"# {self.c['L']['hl'][l]}\n\n" + self.head(l)
        s += "".join(f"- **{k}** — {mdlinks(v)}\n" for k, v in self.c["HL"][l])
        return s + f"\n{self.c['HL_TAIL'][l]}\n"

    def index_html(self, l):
        t, langs, T = self.c["IDX"][l], self.c["LANGS"], self.c["T"]
        trs = []
        for n, k in enumerate(DOCS, 1):
            cs = []
            for fl in langs:
                b = self.files(fl)[k]
                cs.append(
                    f'<span class="lang">{fl.upper()}</span> <a href="{fl}/{b}.html">html</a> · '
                    f'<a href="{fl}/{b}.pdf">pdf</a> · <a href="{fl}/{b}.docx">docx</a>'
                )
            trs.append(
                f"<tr><td>1.{n}</td><td><b>{self.c['NAMES'][l][n - 1]}</b></td>"
                f"<td>{t['rows'][n - 1]}</td><td class='files'>{'<br>'.join(cs)}</td></tr>"
            )
        c = t["cols"]
        links = " · ".join(f'<a href="index.{x}.html">{x.upper()}</a>' for x in langs)
        sub = f"{T['role'][l].replace('&', '&amp;')} · {T['terms'][l]} · {self.name} · {T['date'][l]} · {links}"
        title = H.escape(self.c.get("ROLE_TITLE", self.role))
        return (
            f'<!DOCTYPE html>\n<html lang="{l}">\n<head>\n<meta charset="utf-8">\n'
            f'<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            f"<title>{t['toc']} – {title}</title>\n{asset('index_style.html')}\n</head>\n<body>\n"
            f'<div class="card">\n<h1>{t["toc"]}</h1>\n<p class="sub">{sub}</p>\n<table>\n'
            f"<thead><tr><th>{c[0]}</th><th>{c[1]}</th><th>{c[2]}</th><th>{c[3]}</th></tr></thead>\n"
            f'<tbody>\n<tr class="grp"><td>1</td><td colspan="3">{t["grp"]}</td></tr>\n'
            + "\n".join(trs)
            + "\n</tbody>\n</table>\n</div>\n</body>\n</html>\n"
        )

    # --- the cover letter (the why-letter) ---------------------------------------

    def letter_html(self, l):
        w, f = self.letter[l], self.files(l)
        script = asset("why_script.html").replace(
            'wire("copy", "msg-en", "Copy EN", "Copied ✓");',
            f'wire("copy", "msg-{l}", "{w["copy"][0]}", "{w["copy"][1]}");',
        )
        att = ", ".join(f"{f[k]}.pdf" for k in ("cv", "hl", "ppr", "rpp"))
        lis = "\n".join(f"    <li><b>{k}:</b> {v}</li>" for k, v in w["li"])
        rows = "\n".join(f"    <tr><th>{k}</th><td>{v}</td></tr>" for k, v in w["rows"])
        demo = f"\n  <p><b>{w['demo']}</b></p>\n" if w.get("demo") else ""
        return (
            f'<!DOCTYPE html>\n<html lang="{l}">\n<head>\n<meta charset="utf-8">\n'
            f'<meta name="viewport" content="width=device-width, initial-scale=1">\n<title>{w["h1"]}</title>\n'
            f'{asset("why_style.html")}\n</head>\n<body>\n<div class="bar">\n'
            f'  <button id="copy" type="button">{w["copy"][0]}</button>\n</div>\n\n<div class="card" id="msg-{l}">\n'
            f'  <div class="meta">\n    <div><b>{w["to"]}:</b> {w["recipient"]}</div>\n'
            f"    <div><b>{w['re']}:</b> {w['subject']}</div>\n    <div><b>{w['att']}:</b> {att}</div>\n"
            f"    <h1>{w['h1']}</h1>\n  </div>\n\n  <p>{w['hi']}</p>\n\n  <p>{w['p1']}</p>\n\n"
            f'  <p class="hook">{w["hook"]}</p>\n\n  <p>{w["p2"]}</p>\n\n  <p><b>{w["why"]}</b></p>\n'
            f"  <ul>\n{lis}\n  </ul>\n\n  <p>{w['adj']}</p>\n{demo}\n  <p>{w['p3']}</p>\n\n"
            f"  <table>\n{rows}\n  </table>\n\n  <p>{w['call']}</p>\n\n"
            f'  <p class="sign">{w["sign"]}<br>{self.name}</p>\n</div>\n\n{script}\n</body>\n</html>\n'
        )

    # --- the CV: the base CV with this vacancy's kicker, tagline and key table ----

    def cv_html(self, l, base):
        cv, L = self.c.get("CV", {}), l.upper()
        s = read(base)
        if cv.get("kicker"):
            s = sub1(
                s,
                r"<title>.*?</title>",
                f"<title>CV {self.name} {L} {self.date[:7]} – {cv['kicker']}</title>",
                l,
                "<title>",
            )
            s = sub1(
                s,
                r'<p class="kicker">.*?</p>',
                f'<p class="kicker">{cv["kicker"]}</p>',
                l,
                '<p class="kicker">',
            )
        if cv.get("tagline"):
            s = sub1(
                s,
                r'<p class="tagline">.*?</p>',
                f'<p class="tagline">{cv["tagline"][L]}</p>',
                l,
                '<p class="tagline">',
            )
        if cv.get("key"):
            s = self.cv_key(s, l)
        drop = {x.lower() for x in cv.get("skills_drop", [])}
        if drop:
            s = re.sub(
                r"(?is)<tr\b[^>]*>.*?</tr>\s*",
                lambda m: "" if (cells(m[0]) or [""])[0].lower() in drop else m[0],
                s,
            )
        reps = cv.get("replace", [])
        for old, new in reps.get(L, []) if isinstance(reps, dict) else reps:
            if s.count(old) != 1:
                raise PackError(
                    f"{l}: a CV replace text occurs {s.count(old)} times in the base CV, not once: {old[:40]!r}"
                )
            s = s.replace(old, new)
        return s

    def cv_key(self, s, l):
        L, cv = l.upper(), self.c["CV"]
        h = cv["key_head"][L]
        rows = "\n".join(
            f'<tr><td class="t">{H.escape(a)}</td><td>{b}</td><td>{c}</td><td>{d}</td>'
            f"<td>{H.escape(e)}</td></tr>"
            for a, b, c, d, e in cv["key"][L]
        )
        table = (
            f'<h2>{h[0]}</h2>\n<table class="key"><thead><tr><th>{h[1]}</th><th>{h[2]}</th><th>{h[3]}</th>'
            f"<th>{h[4]}</th><th>{h[5]}</th></tr></thead>\n<tbody>\n{rows}\n</tbody></table>"
        )
        s2, n = re.subn(
            r'(?s)<h2>[^<]*</h2>\s*<table class="key">.*?</table>',
            lambda m: table,
            s,
            count=1,
        )
        if n == 1:
            return s2
        s2, n = re.subn(
            r'(?s)(<p class="tagline">.*?</p>)',
            lambda m: m[1] + "\n" + table,
            s,
            count=1,
        )
        if n != 1:
            raise PackError(
                f"{l}: the base CV has neither a key table nor a tagline to put one after"
            )
        return s2

    # --- rendering: md -> html/docx (pandoc), html -> pdf (chrome) ----------------

    def run(self, *cmd):
        try:
            r = subprocess.run(list(cmd), capture_output=True, text=True)
        except OSError as e:
            raise PackError(f"cannot run {cmd[0]}: {e.strerror or e}") from e
        if r.returncode != 0:
            raise PackError(
                f"{os.path.basename(cmd[0])} failed (rc {r.returncode}): {r.stderr.strip()[:300]}"
            )

    def pdf(self, page, out):
        self.run(
            self.tools["chrome"],
            "--headless=new",
            "--no-sandbox",
            "--disable-gpu",
            "--no-pdf-header-footer",
            f"--user-data-dir={self.out}/internal/chrome-profile",
            f"--print-to-pdf={out}",
            "file://" + page,
        )

    def build_md_docs(self, l, d):
        f, pandoc = self.files(l), self.tools["pandoc"]
        for k, fn in (("hl", self.md_hl), ("ppr", self.md_ppr), ("rpp", self.md_rpp)):
            md = os.path.join(self.md_dir, f"{f[k]}.md")
            write(md, fn(l))
            title = f"{self.c['L'][k][l]} — {self.name}"
            self.run(
                pandoc,
                md,
                "-s",
                "-o",
                f"{d}/{f[k]}.html",
                f"--include-in-header={ASSETS}/head.html",
                "--metadata",
                f"pagetitle={title}",
                "--metadata",
                f"lang={l}",
            )
            self.run(
                pandoc, md, "-o", f"{d}/{f[k]}.docx", "--metadata", f"title={title}"
            )
            self.pdf(f"{d}/{f[k]}.html", f"{d}/{f[k]}.pdf")

    def build_lang(self, l, base):
        f, d, pandoc = self.files(l), os.path.join(self.dst, l), self.tools["pandoc"]
        os.makedirs(d)
        self.build_md_docs(l, d)
        write(f"{d}/{f['cv']}.html", self.cv_html(l, base))
        self.pdf(f"{d}/{f['cv']}.html", f"{d}/{f['cv']}.pdf")
        self.run(
            pandoc, f"{d}/{f['cv']}.html", "-f", "html", "-o", f"{d}/{f['cv']}.docx"
        )
        letter = self.letter_html(l)
        write(f"{d}/{f['why']}.html", letter)
        wd = os.path.join(self.md_dir, f"{f['why']}.docx.html")
        write(wd, re.sub(r'(?s)<div class="bar">.*?</div>', "", letter, count=1))
        self.run(pandoc, wd, "-f", "html", "-o", f"{d}/{f['why']}.docx")
        self.pdf(f"{d}/{f['why']}.html", f"{d}/{f['why']}.pdf")
        write(os.path.join(self.dst, f"index.{l}.html"), self.index_html(l))

    def build(self, bases):
        langs = self.c["LANGS"]
        missing = [l for l in langs if l not in bases]
        if missing:
            raise PackError(
                f"no base CV for {', '.join(missing)}: pass MASTER_CV_DIR or set CV['base'] in the CONTENT"
            )
        if os.path.isdir(self.dst) and not os.path.isfile(
            os.path.join(self.dst, MARKER)
        ):
            raise PackError(
                f"{self.dst} exists and was not written by job-pack: move it away first"
            )
        shutil.rmtree(self.dst, ignore_errors=True)
        os.makedirs(self.md_dir, exist_ok=True)
        write(
            os.path.join(self.dst, MARKER),
            "written by do_job_pack; the next build replaces this dir\n",
        )
        for l in langs:
            self.build_lang(l, bases[l])
        shutil.copyfile(
            os.path.join(self.dst, f"index.{langs[0]}.html"),
            os.path.join(self.dst, "index.html"),
        )
        shutil.rmtree(
            os.path.join(self.out, "internal", "chrome-profile"), ignore_errors=True
        )
        return self.zip()

    def zip(self):
        z = os.path.join(self.dst, f"{self.pack}.zip")
        with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as zf:
            for p in pack_files(self.dst, z):
                zf.write(p, f"{self.pack}/{os.path.relpath(p, self.dst)}")
        return z


# --- the fit table and the file report ---------------------------------------------


NUM_WORDS = {
    w: i
    for ws in (
        "zero one two three four five six seven eight nine ten eleven twelve "
        "thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty",
        "nolla yksi kaksi kolme neljä viisi kuusi seitsemän kahdeksan yhdeksän kymmenen",
    )
    for i, w in enumerate(ws.split())
}
YEARS_RX = re.compile(
    r"(?i)(\d+(?:[.,]\d+)?|" + "|".join(NUM_WORDS) + r")\s*\+?\s*(\w*)"
)


def years(s):
    """Years in an experience cell: '5', '5+ years', 'five years', '6 months' ->
    5, 5, 5, 0.5; None when it names no number (a CHECK, never a silent keep)."""
    m = YEARS_RX.search(s or "")
    if not m:
        return None
    n = m[1].lower()
    v = NUM_WORDS[n] if n in NUM_WORDS else float(n.replace(",", "."))
    unit = m[2].lower()
    if unit.startswith(("month", "kuukau", "kk", "mån")):
        v /= 12
    return v


def num(v):
    return f"{v:g}" if isinstance(v, (int, float)) else "–"


def master_match(tech, skills):
    hits = [t for t in skills if t.lower() == tech.lower() or named(t, tech)]
    return max(hits, key=len) if hits else None


def fit_status(exp, m, theirs):
    if m is None:
        return "CHECK: not in the master CV skills table"
    mine = years(exp)
    if theirs is None:
        return "CHECK: the master CV gives no years"
    if mine is None:
        return "CHECK: the pack gives no years"
    if abs(mine - theirs) > 1e-9:
        return f"CHECK: master CV says {num(theirs)}"
    return "backed"


def fit(c, bases, text, out):
    """Rule 4 (years only as the master CVs back them) made visible: per language,
    each key-table row against the base CV's skills table, then the vacancy's other
    technologies."""
    checks, parts = 0, []
    for l in c["LANGS"]:
        skills = skills_rows(read(bases[l]))
        rows = [
            "| technology | named in vacancy | master CV years | pack says | status |",
            "|:--|:--|--:|:--|:--|",
        ]
        seen = set()
        for tech, _, exp, _, _ in c.get("CV", {}).get("key", {}).get(l.upper(), []):
            m = master_match(tech, skills)
            theirs = years(skills[m][1]) if m else None
            status = fit_status(exp, m, theirs)
            checks += status.startswith("CHECK")
            seen.add((m or tech).lower())
            in_vac = named(tech, text) or (m is not None and named(m, text))
            rows.append(
                f"| {tech} | {'yes' if in_vac else 'no'} | {num(theirs)} | {exp} | {status} |"
            )
        for t in c.get("KEYWORDS") or [t for t in skills if named(t, text)]:
            if t.lower() in seen:
                continue
            m = master_match(t, skills)
            status = (
                "in the CV skills table only"
                if m
                else "CHECK: the vacancy names it, the CV does not"
            )
            checks += m is None
            rows.append(
                f"| {t} | {'yes' if named(t, text) else 'no'} | {skills[m][1] if m else '–'} | – | {status} |"
            )
        parts.append(f"## {l}\n\n" + "\n".join(rows) + "\n")
    write(
        os.path.join(out, "internal", "fit.md"),
        "# Fit table\n\n" + "\n".join(parts),
    )
    return checks


def pack_files(dst, z):
    for r, _, fs in sorted(os.walk(dst)):
        for n in sorted(fs):
            p = os.path.join(r, n)
            if p != z and n != MARKER:
                yield p


def report(z, out, pdfinfo):
    dst = os.path.dirname(z)
    files = list(pack_files(dst, z))
    rows = ["| file | bytes | pages |", "|:--|--:|--:|"]
    rows += [
        f"| `{os.path.relpath(p, dst)}` | {os.path.getsize(p):,} | {pages(p, pdfinfo)} |"
        for p in files
    ]
    sha = hashlib.sha256(read_bytes(z)).hexdigest()
    rows.append(
        f"\nzip `{os.path.basename(z)}`: {os.path.getsize(z):,} bytes, sha256 `{sha}`"
    )
    write(os.path.join(out, "internal", "files.md"), "\n".join(rows) + "\n")
    return sha, len(files)


def pages(p, pdfinfo):
    if not p.endswith(".pdf") or not shutil.which(pdfinfo):
        return "–"
    o = subprocess.run([pdfinfo, p], capture_output=True, text=True).stdout
    return next((x.split()[1] for x in o.splitlines() if x.startswith("Pages")), "–")


# --- helpers ----------------------------------------------------------------------


def mdlinks(s):
    return re.sub(r'<a href="([^"]+)">([^<]+)</a>', r"[\2](\1)", s)


def esc(s):
    return mdlinks(s).replace("|", "\\|")


def sub1(s, rx, new, l, what):
    s2, n = re.subn("(?s)" + rx, lambda m: new, s, count=1)
    if n != 1:
        raise PackError(f"{l}: the base CV has no {what}")
    return s2


def asset(n):
    return read(os.path.join(ASSETS, n))


def read(p):
    with open(p, encoding="utf-8") as fh:
        return fh.read()


def read_bytes(p):
    with open(p, "rb") as fh:
        return fh.read()


def write(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(s)


def load_content(p):
    c = runpy.run_path(p)
    missing = [k for k in REQUIRED if k not in c] + (
        [] if ("LETTER" in c or "W" in c) else ["LETTER"]
    )
    if missing:
        raise PackError(
            f"CONTENT {p} lacks {', '.join(missing)} (contract: csi-spl-doc/doc/md/job-pack.md section 3)"
        )
    return c


def content_bases(c, master):
    base = c.get("CV", {}).get("base", {})
    return {
        l: (p if os.path.isabs(p) or not master else os.path.join(master, p))
        for l, p in base.items()
    }


def build(o, out, text, bases):
    c = load_content(o.content)
    bases.update(content_bases(c, o.master_cv_dir))
    z = Pack(c, out, {"pandoc": o.pandoc, "chrome": o.chrome}).build(bases)
    checks = fit(c, bases, text, out)
    sha, n = report(z, out, o.pdfinfo)
    print(f"OK build: {n} files in {len(c['LANGS'])} language(s), zip {z} sha256 {sha}")
    print(
        f"{'WARN' if checks else 'OK'} fit: {checks} row(s) to CHECK in {out}/internal/fit.md"
    )


def main(argv):
    a = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    a.add_argument("--out", required=True)
    a.add_argument("--vacancy-url", default="")
    a.add_argument("--master-cv-dir", default="")
    a.add_argument("--content", default="")
    a.add_argument("--pandoc", default="pandoc")
    a.add_argument("--chrome", default="google-chrome")
    a.add_argument("--pdfinfo", default="pdfinfo")
    o = a.parse_args(argv)
    out = os.path.abspath(o.out)
    try:
        text = fetch(o.vacancy_url, out) if o.vacancy_url else vacancy_text(out)
        bases = pick(o.master_cv_dir, text, out) if o.master_cv_dir else {}
        if not o.content:
            print(
                f"NEXT job-pack: write the CONTENT file (csi-spl-doc/doc/md/job-pack.md section 3), "
                f"then re-run with CONTENT=<file> OUT_DIR={out}"
            )
            return 0
        build(o, out, text, bases)
    except FetchError as e:
        print(f"FATAL job-pack: {e}")
        return 3
    except PackError as e:
        print(f"FATAL job-pack: {e}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
