# Synthetic CONTENT for job-pack.tst.sh and the template of a real one
# (contract: csi-spl-doc/doc/md/job-pack.md section 3). No real person,
# employer or vacancy: a real CONTENT lives outside git, next to its pack.
NAME = "FirstName LastName"
ROLE = "Platform-Engineer"
ROLE_TITLE = "Platform Engineer"
DATE = "2026-11-15"
LANGS = ["en", "fi"]
CONTACT = "firstname.lastname@example.com · +000 00 000 0000"
KEYWORDS = ["Terraform", "Kafka", "Rust"]

T = {
    "role": {"en": "Platform Engineer", "fi": "Platform Engineer"},
    "terms": {"en": "Example Corp · 6 months", "fi": "Example Corp · 6 kk"},
    "avail": {"en": "available 2027-01", "fi": "vapaana 2027-01"},
    "date": {"en": "15.11.2026", "fi": "15.11.2026"},
}
L = {
    "hl": {"en": "Highlights", "fi": "Kohokohdat"},
    "ppr": {"en": "Projects per requirement", "fi": "Projektit vaatimuksittain"},
    "rpp": {"en": "Requirements per project", "fi": "Vaatimukset projekteittain"},
    "ppr_intro": {
        "en": "Each requirement with the projects that meet it.",
        "fi": "Jokainen vaatimus ja sen täyttävät projektit.",
    },
    "rpp_intro": {
        "en": "Each project with the requirements it meets.",
        "fi": "Jokainen projekti ja sen täyttämät vaatimukset.",
    },
    "summary": {"en": "Summary", "fi": "Yhteenveto"},
    "req": {"en": "Requirement", "fi": "Vaatimus"},
    "reqs": {"en": "Requirements", "fi": "Vaatimukset"},
    "projs": {"en": "Projects", "fi": "Projektit"},
    "proj": {"en": "Project", "fi": "Projekti"},
    "how": {"en": "How", "fi": "Miten"},
}
PR = {
    "alpha": {"en": "Example Corp 2020–2024", "fi": "Example Corp 2020–2024"},
    "beta": {"en": "Example Org 2018–2020", "fi": "Example Org 2018–2020"},
}
PROJ_ORDER = ["alpha", "beta"]
REQ = [
    (
        "1.1",
        {"en": "Terraform", "fi": "Terraform"},
        [
            (
                "alpha",
                {
                    "en": "SYNTH-ALPHA-TF: all infra as code",
                    "fi": "SYNTH-ALPHA-TF: kaikki infra koodina",
                },
            ),
            (
                "beta",
                {
                    "en": "SYNTH-BETA-TF: modules | pipelines",
                    "fi": "SYNTH-BETA-TF: moduulit",
                },
            ),
        ],
        {"en": "SYNTH-NOTE-1", "fi": "SYNTH-HUOM-1"},
    ),
    (
        "1.2",
        {"en": "Kafka", "fi": "Kafka"},
        [
            (
                "alpha",
                {
                    "en": "SYNTH-ALPHA-KAFKA: event pipeline",
                    "fi": "SYNTH-ALPHA-KAFKA: tapahtumaputki",
                },
            )
        ],
        {"en": "SYNTH-NOTE-2", "fi": "SYNTH-HUOM-2"},
    ),
]
PROJ_HOW = {
    "alpha": {"en": "SYNTH-HOW-ALPHA", "fi": "SYNTH-MITEN-ALPHA"},
    "beta": {"en": "SYNTH-HOW-BETA", "fi": "SYNTH-MITEN-BETA"},
}
HL = {
    "en": [
        (
            "Infra as code",
            'SYNTH-HL-1, see <a href="https://example.com">example.com</a>',
        ),
        ("Events", "SYNTH-HL-2"),
    ],
    "fi": [("Infra koodina", "SYNTH-HL-1"), ("Tapahtumat", "SYNTH-HL-2")],
}
HL_TAIL = {"en": "SYNTH-HL-TAIL", "fi": "SYNTH-HL-LOPPU"}
IDX = {
    "en": {
        "toc": "Contents",
        "cols": ("#", "Document", "What it contains", "Files"),
        "grp": "Documents",
        "rows": [
            "the CV",
            "one page",
            "requirement -> projects",
            "project -> requirements",
            "the letter",
        ],
    },
    "fi": {
        "toc": "Sisältö",
        "cols": ("#", "Dokumentti", "Sisältö", "Tiedostot"),
        "grp": "Dokumentit",
        "rows": [
            "CV",
            "yksi sivu",
            "vaatimus -> projektit",
            "projekti -> vaatimukset",
            "kirje",
        ],
    },
}
NAMES = {
    "en": [
        "CV",
        "Highlights",
        "Projects per requirement",
        "Requirements per project",
        "Why me for this role",
    ],
    "fi": [
        "CV",
        "Kohokohdat",
        "Projektit vaatimuksittain",
        "Vaatimukset projekteittain",
        "Miksi minä tähän rooliin",
    ],
}


def _letter(hi, recipient, sign):
    return {
        "copy": ("Copy", "Copied ✓"),
        "to": "To",
        "re": "Re",
        "att": "Attachments",
        "recipient": recipient,
        "subject": "SYNTH-SUBJECT Platform Engineer",
        "h1": "Platform Engineer – FirstName LastName",
        "hi": hi,
        "p1": "SYNTH-P1",
        "hook": "SYNTH-HOOK",
        "p2": "SYNTH-P2",
        "why": "SYNTH-WHY",
        "li": [("Terraform", "SYNTH-LI-1"), ("Kafka", "SYNTH-LI-2")],
        "adj": "SYNTH-ADJ: Rust is adjacent experience only.",
        "demo": "",
        "p3": "SYNTH-P3",
        "rows": [
            ("Name", "FirstName LastName"),
            ("Email", "firstname.lastname@example.com"),
        ],
        "call": "SYNTH-CALL",
        "sign": sign,
    }


LETTER = {
    "en": _letter("Hello,", "jobs@example.com", "Best regards"),
    "fi": _letter("Hei,", "jobs@example.com", "Ystävällisin terveisin"),
}

CV = {
    "kicker": "Platform Engineer · Terraform · Kafka",
    "tagline": {"EN": "SYNTH-TAGLINE-EN", "FI": "SYNTH-TAGLINE-FI"},
    "key_head": {
        "EN": (
            "Key technologies",
            "Technology",
            "Level (1–5)",
            "Experience",
            "Last used",
            "Projects",
        ),
        "FI": (
            "Keskeiset teknologiat",
            "Teknologia",
            "Taso (1–5)",
            "Kokemus",
            "Viimeksi",
            "Projektit",
        ),
    },
    "key": {
        "EN": [
            ("Terraform", "5", "5 years", "2026", "SYNTH-KEY-TF"),
            ("Kafka", "4", "4 years", "2025", "SYNTH-KEY-KAFKA"),
        ],
        "FI": [
            ("Terraform", "5", "5 vuotta", "2026", "SYNTH-KEY-TF"),
            ("Kafka", "4", "4 vuotta", "2025", "SYNTH-KEY-KAFKA"),
        ],
    },
    "skills_drop": ["Cobol"],
    "replace": {
        "EN": [("synthetic project alpha", "synthetic project alpha (event pipelines)")]
    },
}
