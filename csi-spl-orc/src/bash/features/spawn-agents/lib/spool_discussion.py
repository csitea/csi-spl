"""spool_discussion.py - which discussion a seated agent's turn belongs to, and
whether its final text may go there (SPL-4657, spec 067 section 11).

The decisions only: no send, no hub call. spool-mirror.py runs them, reads the
hub, and posts. Every answer here that is not a yes names why, and that reason
is what the mirror logs: never the text.

Behind cnf env.box.discussion_mirror (enabled, max_posts_per_hour), in
<repo>/csi-spl-cnf/csi-spl/{all,<env>}.env.yaml. A missing key, a missing file
or a file that does not parse reads as OFF.
"""

import datetime
import glob
import json
import os
import re

UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
UUID_RE = re.compile(r"^" + UUID + r"$")
# The brief's Discussion: line only, at the start of its line: a link cited
# anywhere else in a brief is history, not this lane's discussion. A full uuid
# only: lib/lane-issue.inc.sh also accepts a short id, which names no topic the
# hub can be asked about.
BRIEF_RE = re.compile(
    r"^[ \t>*_-]*[Dd]iscussion[*_: ]+`?(?:https?://\S*?/t/)?("
    + UUID
    + r")(?![0-9A-Za-z-])",
    re.MULTILINE,
)
# lib/spool-env.inc.sh SPL_ROLE_SEAT_RX, and the legacy forms it accepts.
ROLE_RE = re.compile(r"^(?:[acgmoqu]|CLE|GRK|AGY|QWN)-00[1-3](?:@[A-Za-z0-9._-]+)?$")
SEEN_TTL = 24 * 3600  # a channel post older than this no longer names a discussion
DEFAULT_MAX_PER_HOUR = 12
# A follow-up of a person's DM can be as private as its answer, and nothing marks
# it: a background job's report is one more notification turn. A session lasts at
# most an hour and its background jobs end with it, hence the window.
DM_HOLD = 3600


def _cnf_dir():
    return os.environ.get("SPOOL_DISCUSSION_MIRROR_CNF") or os.path.join(
        os.path.dirname(os.path.realpath(__file__)),
        *[".."] * 6,
        "csi-spl-cnf",
        "csi-spl",
    )


def _cnf_block(name):
    import yaml  # only when a post is possible: the hook's fast path never gets here

    with open(os.path.join(_cnf_dir(), name + ".env.yaml")) as f:
        d = yaml.safe_load(f)
    return ((d or {}).get("env") or {}).get("box", {}).get("discussion_mirror") or {}


def settings(env):
    """{enabled, max_posts_per_hour} for env: <env>.env.yaml over all.env.yaml.
    Anything unreadable in all.env.yaml, or a broken <env> file, is OFF."""
    off = {"enabled": False, "max_posts_per_hour": DEFAULT_MAX_PER_HOUR}
    try:
        merged = dict(off, **_cnf_block("all"))
    except Exception:  # noqa: BLE001 - no yaml module, no file, no parse: off
        return off
    try:
        merged.update(_cnf_block(env))
    except FileNotFoundError:
        pass
    except Exception:  # noqa: BLE001 - a broken env file must not read as on
        return off
    merged["enabled"] = merged.get("enabled") is True
    return merged


def seat_env_name(seat):
    """<root>/<env>/desk/<workspace>/<box> -> <env>."""
    parts = seat.rstrip("/").split("/")
    return parts[-4] if len(parts) >= 4 else ""


def is_role_seat(agent):
    return bool(ROLE_RE.match(agent))


def fleet_root():
    return os.environ.get("SPOOL_ROOT") or "/var/spool-hub"


def brief_discussions(agent):
    """The distinct full uuids on the Discussion: lines of the lane's brief."""
    try:
        with open(
            os.path.join(fleet_root(), agent, "lifetime", "brief.md"), errors="replace"
        ) as f:
            return sorted(set(BRIEF_RE.findall(f.read())))
    except OSError:
        return []


def _seen_path(adir):
    return os.path.join(adir, ".mirror", "discussions")


def _read_json(p):
    try:
        with open(p) as f:
            v = json.load(f)
        return v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_json(p, v):
    tmp = "%s.tmp.%d" % (p, os.getpid())
    with open(tmp, "w") as f:
        json.dump(v, f)
    os.replace(tmp, p)


def note_channel_post(adir, task, now):
    """A channel post on task reached this seat: it names a discussion for a
    day. Kept while the switch is off, so turning it on starts with history."""
    if not UUID_RE.match(str(task or "")):
        return
    os.makedirs(os.path.join(adir, ".mirror"), exist_ok=True)
    seen = {
        k: v for k, v in _read_json(_seen_path(adir)).items() if now - v <= SEEN_TTL
    }
    seen[task] = now
    _write_json(_seen_path(adir), seen)


def _dm_turn_path(adir):
    return os.path.join(adir, ".mirror", "dm-turn")


def note_dm_turn(adir, now):
    """A person's DM started a turn. Written at the prompt, so it holds for every
    hook of that turn's answer and for the turns that follow it."""
    os.makedirs(os.path.join(adir, ".mirror"), exist_ok=True)
    _write_json(_dm_turn_path(adir), {"ts": now})


def dm_hold(adir, now):
    """A DM turn began on this seat within DM_HOLD. A record that cannot be read
    is a hold: a wrong landing is worse than silence."""
    try:
        with open(_dm_turn_path(adir)) as f:
            return now - float(json.load(f)["ts"]) < DM_HOLD
    except FileNotFoundError:
        return False
    except (OSError, ValueError, KeyError, TypeError):
        return True


def resolve(adir, agent, turn, now):
    """-> (task, '') or ('', why nothing): the spec's order. The turn's own
    channel post, the brief's one discussion, the one topic seen lately. Two
    named or seen and no turn of their own: silence, a wrong landing is worse."""
    task = str(turn.get("task") or "")
    if turn.get("kind") == "channel" and UUID_RE.match(task):
        return task, ""
    named = brief_discussions(agent)
    if len(named) == 1:
        return named[0], ""
    if named:
        return "", "the brief names %d discussions" % len(named)
    seen = [k for k, v in _read_json(_seen_path(adir)).items() if now - v <= SEEN_TTL]
    if len(seen) == 1:
        return seen[0], ""
    if not seen:
        return "", "no discussion known for this seat"
    return "", "%d discussions and this turn names none" % len(seen)


def parse_rows(out):
    """hub-tail --with-channel NDJSON -> its dict rows."""
    rows = []
    for line in str(out or "").splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if isinstance(d, dict):
            rows.append(d)
    return rows


def channel_of(rows):
    """The channel the topic's rows carry, '' for none (a DM, or nothing read)."""
    return next((str(r["channel"]) for r in rows if r.get("channel")), "")


def _epoch(ts):
    try:
        return datetime.datetime.fromisoformat(
            str(ts).replace("Z", "+00:00")
        ).timestamp()
    except ValueError:
        return 0.0


def _same(a, b):
    return " ".join(str(a or "").split()) == " ".join(str(b or "").split())


def already_posted(adir, agent, task, rows, text, since):
    """Why this turn's text is not posted, else ''. A closing summary rarely
    matches its post word for word, so the check is per turn: any post of the
    agent into this topic since the turn began. The hub is the truth for every
    vendor; the seat's outbox holds a send the sidecar has not flushed yet."""
    for r in rows:
        if str(r.get("from")) != agent:
            continue
        if _same(r.get("body"), text):
            return "the same text is already in the topic"
        # ts is whole seconds on both sides: the same second counts as this turn.
        if since and _epoch(r.get("ts")) >= int(since):
            return "the agent posted in the topic during this turn"
    if since:
        for p in glob.glob(os.path.join(adir, "outbox", "*")):
            try:
                if (
                    os.path.getmtime(p) >= since
                    and _read_json(p).get("task_id") == task
                ):
                    return "the agent sent to the topic during this turn"
            except OSError:
                pass
    return ""


def rate_take(adir, max_per_hour, now):
    """-> (allowed, skipped since the last post). Refused: the skip is counted
    for the next post to say. Allowed: the slot is taken, the count is cleared
    by rate_posted once the send has succeeded."""
    p = os.path.join(adir, ".mirror", "discussion-rate")
    d = _read_json(p)
    posts = [t for t in d.get("posts") or [] if now - t < 3600]
    skipped = int(d.get("skipped") or 0)
    if len(posts) >= int(max_per_hour):
        _write_json(p, {"posts": posts, "skipped": skipped + 1})
        return False, skipped + 1
    return True, skipped


def rate_posted(adir, now):
    p = os.path.join(adir, ".mirror", "discussion-rate")
    d = _read_json(p)
    posts = [t for t in d.get("posts") or [] if now - t < 3600] + [now]
    _write_json(p, {"posts": posts, "skipped": 0})
