#!/usr/bin/env python3
"""
LightRAG entity deduplication pipeline.

Stages:
  1.    Rule-based normalization: case-fold + token reorder + acronym-aware
        singularization (acronyms and digit-containing tokens are preserved).
  1.5.  Morphological core-stem equivalence (phase/process wrappers).
  1.75. Explicit alias file (--aliases).
  2.    Embedding similarity verdicts. Only cosine >= --auto-cos (default 0.97)
        auto-merges; everything in [--gray-min, --auto-cos) goes to the LLM.
  3.    Two-way LLM verification (A->B and B->A) with a stricter prompt.
  4.    Cannot-link-aware application of merges, strongest-first.
"""

import argparse
import json
import math
import re
from itertools import combinations
from pathlib import Path

import requests
from nltk.stem import PorterStemmer


META_TOKENS = {
    "phase", "stage", "step", "process", "procedure",
    "method", "technique", "approach", "operation",
}

INTERNAL_ID_PATTERN = re.compile(r"^(im|tb|doc)-[a-f0-9]+")

FEW_SHOT_EXAMPLES = """Entity A: engine
Entity B: car
Answer: no

Entity A: CPU
Entity B: processor
Answer: yes

Entity A: firewall
Entity B: host firewall
Answer: no

Entity A: error log
Entity B: log file
Answer: no"""

SYSTEM_PROMPT = (
    "You are given two entity names extracted from technical documentation. "
    "Decide whether they are the same concept.\n\n"
    '"Same concept" means they are interchangeable in any sentence with no '
    "change in meaning. If they are merely related, one is part of the other, "
    "or they belong to the same category, answer no.\n\n"
    "Examples:\n{examples}"
)


# ---------------------------------------------------------------------------
# Tokenization / normalization
# ---------------------------------------------------------------------------

def tokenize(name: str):
    """Acronym-aware singularization.

    Tokens that are fully uppercase or contain a digit are left verbatim so
    that acronyms like 'HTTPS' or 'DDR4' are not singularized. Regular tokens
    ending in 'ies' are converted to 'y'; a trailing 's' is stripped otherwise.
    """
    out = []
    for w in re.findall(r"[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*", name):
        lw = w.casefold()
        if w.isupper() or any(c.isdigit() for c in w):
            out.append(lw)
        elif lw.endswith("ies") and len(lw) > 4:
            out.append(lw[:-3] + "y")
        elif lw.endswith("s") and not lw.endswith(("ss", "us", "is")) and len(lw) > 3:
            out.append(lw[:-1])
        else:
            out.append(lw)
    return out


def normalized_key(name: str):
    return tuple(sorted(tokenize(name)))


# ---------------------------------------------------------------------------
# Short names and acronym matching
# ---------------------------------------------------------------------------

def _is_subseq(short: str, long: str) -> bool:
    it = iter(long)
    return all(c in it for c in short)


def acronym_match(short: str, long: str) -> bool:
    """True iff the short name's letters appear in order in the long name's
    initials AND in its full token stream, AND the long name has >= 2 tokens.

    The len(toks) < 2 guard is what blocks `dc` -> `dccla` — a single-token
    long name has no meaningful initials to match against.
    """
    s = re.sub(r"[^a-z0-9]", "", short.casefold())
    toks = re.findall(r"[a-z0-9]+", long.casefold())
    if len(toks) < 2 or not s or s[0] != toks[0][0]:
        return False
    initials = "".join(t[0] for t in toks)
    return _is_subseq(initials, s) and _is_subseq(s, "".join(toks))


def is_short(name: str) -> bool:
    return len(re.sub(r"[^A-Za-z0-9]", "", name)) <= 3


def short_name_allowed(a: str, b: str, mention_counts=None, min_mentions: int = 2) -> bool:
    """Gate for pairs that involve a very short name.

    Allowed when:
      * neither side is short, OR
      * the short side is an acronym match for the long side, OR
      * the short side is mentioned at least `min_mentions` times in the
        corpus (evidence gate — recovers CPU/RAM/PC without letting one-off
        OCR junk like `dc`/`MUL` through).

    Two short names together are allowed only when they are acronym matches,
    so junk-vs-junk merges stay blocked.
    """
    a_short = is_short(a)
    b_short = is_short(b)

    if not a_short and not b_short:
        return True

    if a_short and b_short:
        return acronym_match(a, b)

    short, long = (a, b) if a_short else (b, a)
    if acronym_match(short, long):
        return True

    if mention_counts is not None and mention_counts.get(short, 0) >= min_mentions:
        return True

    return False


# ---------------------------------------------------------------------------
# Canonical choice
# ---------------------------------------------------------------------------

def load_mention_counts(storage_dir: str):
    """Best-effort load of per-entity chunk counts from kv_store_entity_chunks.json."""
    p = Path(storage_dir) / "kv_store_entity_chunks.json"
    if not p.exists():
        print(f"[warn] {p} not found; canonical choice falls back to capitals heuristic")
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"[warn] failed to parse {p}: {e}")
        return None

    counts = {}
    for ent, val in data.items():
        if isinstance(val, list):
            counts[ent] = len(val)
        elif isinstance(val, dict):
            inner = val.get("chunks") or val.get("chunk_ids") or val.get("ids")
            if isinstance(inner, list):
                counts[ent] = len(inner)
            else:
                counts[ent] = 1
        else:
            counts[ent] = 1
    return counts


def canonical(names, mention_counts=None):
    """Pick the target of a merge group.

    Primary criterion is the number of chunks the entity appears in; ties are
    broken by the old capitals/length heuristic. A short token with fewer
    than two mentions is treated as likely junk and deprioritised.
    """
    def score(s):
        mentions = mention_counts.get(s, 0) if mention_counts else 0
        short_junk = is_short(s) and mentions < 2
        return (
            0 if short_junk else 1,
            mentions,
            sum(1 for c in s if c.isupper()),
            len(s),
            s,
        )
    return max(names, key=score)


# ---------------------------------------------------------------------------
# Structural / morphological guards
# ---------------------------------------------------------------------------

def levenshtein(s1, s2):
    if len(s1) < len(s2):
        return levenshtein(s2, s1)
    if len(s2) == 0:
        return len(s1)
    previous_row = range(len(s2) + 1)
    for i, c1 in enumerate(s1):
        current_row = [i + 1]
        for j, c2 in enumerate(s2):
            insertions = previous_row[j + 1] + 1
            deletions = current_row[j] + 1
            substitutions = previous_row[j] + (c1 != c2)
            current_row.append(min(insertions, deletions, substitutions))
        previous_row = current_row
    return previous_row[-1]


def is_blocked(a: str, b: str) -> bool:
    """Structural guards: internal IDs, proper subsets, siblings."""
    if INTERNAL_ID_PATTERN.match(a) or INTERNAL_ID_PATTERN.match(b):
        return True

    ta = set(tokenize(a))
    tb = set(tokenize(b))

    if ta and tb and ta != tb and (ta < tb or tb < ta):
        return True

    if ta & tb:
        unique_to_a = ta - tb
        unique_to_b = tb - ta
        if unique_to_a and unique_to_b:
            return True

    return False


def is_morphological_equivalent(a, b, max_edit_distance=2):
    """Detect `Prepare` vs `Preparation Phase` style equivalences."""
    tokens_a = set(tokenize(a))
    tokens_b = set(tokenize(b))

    if not (tokens_a & META_TOKENS or tokens_b & META_TOKENS):
        return False

    stemmer = PorterStemmer()
    ca = tuple(sorted(stemmer.stem(w) for w in (tokens_a - META_TOKENS)))
    cb = tuple(sorted(stemmer.stem(w) for w in (tokens_b - META_TOKENS)))

    if not ca or not cb or len(ca) != len(cb):
        return False

    used = set()
    for sa in ca:
        matched = False
        for i, sb in enumerate(cb):
            if i in used:
                continue
            if sa == sb:
                used.add(i); matched = True; break
            if len(sa) < 3 or len(sb) < 3 or sa[:3] != sb[:3]:
                continue
            if levenshtein(sa, sb) <= max_edit_distance:
                used.add(i); matched = True; break
        if not matched:
            return False
    return True


# ---------------------------------------------------------------------------
# DSU
# ---------------------------------------------------------------------------

class DSU:
    def __init__(self, items):
        self.parent = {x: x for x in items}

    def find(self, x):
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[rb] = ra

    def groups(self):
        out = {}
        for x in self.parent:
            out.setdefault(self.find(x), []).append(x)
        return list(out.values())


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

def load_entities(storage_dir: str):
    p = Path(storage_dir) / "kv_store_full_entities.json"
    if not p.exists():
        raise FileNotFoundError(f"Missing {p}")
    data = json.loads(p.read_text(encoding="utf-8"))
    names = set()
    for doc in data.values():
        for n in doc.get("entity_names", []):
            names.add(n)
    return sorted(names)


def get_embeddings(texts, url, model, api_key=None):
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    payload = {"model": model, "input": texts}
    r = requests.post(f"{url.rstrip('/')}/embeddings", json=payload,
                      headers=headers, timeout=120)
    r.raise_for_status()
    items = sorted(r.json()["data"], key=lambda x: x["index"])
    return [it["embedding"] for it in items]


def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0.0 or nb == 0.0:
        return 0.0
    return dot / (na * nb)


# ---------------------------------------------------------------------------
# LLM verification (two-way)
# ---------------------------------------------------------------------------

def _llm_verify_once(a, b, url, model):
    system = SYSTEM_PROMPT.format(examples=FEW_SHOT_EXAMPLES)
    user = f"Entity A: {a}\nEntity B: {b}\nAnswer:"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "max_tokens": 4,
        "temperature": 0,
    }
    r = requests.post(f"{url.rstrip('/')}/chat/completions", json=payload, timeout=120)
    r.raise_for_status()
    content = r.json()["choices"][0]["message"].get("content", "").strip().lower()
    if content.startswith("yes"):
        return True, content
    if content.startswith("no"):
        return False, content
    return False, content or "<empty>"


def llm_verify(a, b, url, model):
    ok1, c1 = _llm_verify_once(a, b, url, model)
    if not ok1:
        return False, f"A={a} vs B={b} -> {c1}"
    ok2, c2 = _llm_verify_once(b, a, url, model)
    if not ok2:
        return False, f"B={b} vs A={a} -> {c2}"
    return True, "both yes"


# ---------------------------------------------------------------------------
# Merge endpoint
# ---------------------------------------------------------------------------

def merge_entities(sources, target, lightrag_url, api_key=None, dry_run=False):
    if dry_run:
        print(f"[dry-run] merge {sources} -> {target}")
        return True
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["X-API-Key"] = api_key
    payload = {"entities_to_change": sources, "entity_to_change_into": target}
    r = requests.post(f"{lightrag_url.rstrip('/')}/graph/entities/merge",
                      json=payload, headers=headers, timeout=600)
    r.raise_for_status()
    print(f"merged {sources} -> {target}: HTTP {r.status_code}")
    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--storage-dir", default="./lightRAG/rag_storage")
    ap.add_argument("--lightrag-url", default="http://10.10.0.5:9621")
    ap.add_argument("--embedding-url", default="http://10.10.0.11:9932/v1")
    ap.add_argument("--llm-url", default="http://10.10.0.11:9931/v1")
    ap.add_argument("--embedding-model", default="Qwen3-Embedding-0.6B-f16")
    ap.add_argument("--llm-model", default="Qwen3.5-4B-Q4_K_M")
    ap.add_argument("--log", default="dedupe_decisions.jsonl")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--auto-cos", type=float, default=0.97,
                    help="Cosine >= this auto-merges without LLM (default 0.97)")
    ap.add_argument("--gray-min", type=float, default=0.70,
                    help="Minimum cosine for LLM verification (default 0.70)")
    ap.add_argument("--min-short-mentions", type=int, default=2,
                    help="Mention count needed to bypass the short-name gate")
    ap.add_argument("--aliases", default=None,
                    help="JSON file listing [a, b] pairs to merge unconditionally")
    args = ap.parse_args()

    entities = load_entities(args.storage_dir)
    print(f"loaded {len(entities)} entities")

    mention_counts = load_mention_counts(args.storage_dir)

    aliases = []
    if args.aliases:
        alias_data = json.loads(Path(args.aliases).read_text(encoding="utf-8"))
        for pair in alias_data:
            if isinstance(pair, (list, tuple)) and len(pair) == 2:
                aliases.append((pair[0], pair[1]))
    print(f"loaded {len(aliases)} alias pairs")

    logf = open(args.log, "w", encoding="utf-8")

    def log(rec):
        logf.write(json.dumps(rec, ensure_ascii=False) + "\n")
        logf.flush()

    accept_pairs = []          # list of {sort_key, a, b, source}
    reject_pairs = set()       # frozenset({a, b}) that must never merge

    def add_accept(sort_key, a, b, source):
        if frozenset({a, b}) in reject_pairs:
            log({"stage": "apply", "entity_a": a, "entity_b": b,
                 "decision": "skip", "reason": f"already rejected (source={source})"})
            return
        accept_pairs.append({"sort_key": sort_key, "a": a, "b": b, "source": source})

    def add_reject(a, b, stage, reason, extra=None):
        reject_pairs.add(frozenset({a, b}))
        rec = {"stage": stage, "entity_a": a, "entity_b": b,
               "decision": "reject", "reason": reason}
        if extra:
            rec.update(extra)
        log(rec)

    # ------------------------------------------------------------------
    # Pass 1: gather all decisions
    # ------------------------------------------------------------------

    # Stage 1: normalized-key groups
    groups1 = {}
    for e in entities:
        groups1.setdefault(normalized_key(e), []).append(e)

    rep_lookup = {}
    reps = []
    for key, group in groups1.items():
        target = canonical(group, mention_counts)
        for e in group:
            rep_lookup[e] = target
        reps.append(target)

    for key, group in groups1.items():
        target = rep_lookup[group[0]]
        for src in group:
            if src == target:
                continue
            add_accept((0, 0, 0), src, target, "stage1")
            log({"stage": 1, "entity_a": src, "entity_b": target,
                 "decision": "candidate", "reason": f"normalized key {key}"})

    # Stage 1.75: aliases
    for a, b in aliases:
        rep_a = rep_lookup.get(a)
        rep_b = rep_lookup.get(b)
        if rep_a is None or rep_b is None:
            log({"stage": 1.75, "entity_a": a, "entity_b": b,
                 "decision": "skip", "reason": "entity not in corpus"})
            continue
        if rep_a == rep_b:
            log({"stage": 1.75, "entity_a": a, "entity_b": b,
                 "decision": "skip", "reason": "already in same normalized group"})
            continue
        add_accept((0.5, 0, 0), rep_a, rep_b, "alias")
        log({"stage": 1.75, "entity_a": rep_a, "entity_b": rep_b,
             "decision": "candidate", "reason": "alias"})

    # Stage 1.5: morphological equivalence among reps
    accepted_set = {frozenset({p["a"], p["b"]}) for p in accept_pairs}
    for a, b in combinations(reps, 2):
        if a == b or frozenset({a, b}) in accepted_set:
            continue
        if is_blocked(a, b):
            add_reject(a, b, 1.5, "blocked by structural guard")
            continue
        if not short_name_allowed(a, b, mention_counts, args.min_short_mentions):
            add_reject(a, b, 1.5, "short-name rule")
            continue
        if is_morphological_equivalent(a, b):
            add_accept((1.0, 0, 0), a, b, "stage1.5")
            log({"stage": 1.5, "entity_a": a, "entity_b": b,
                 "decision": "candidate",
                 "reason": "morphological core-stem equivalence"})

    print(f"Stage 1/1.5/alias: {len(reps)} reps, {len(accept_pairs)} candidates, "
          f"{len(reject_pairs)} rejects")

    # Stage 2: cosine verdicts
    print("embedding representatives...")
    embs = get_embeddings(reps, args.embedding_url, args.embedding_model)
    emb_map = dict(zip(reps, embs))

    accepted_set = {frozenset({p["a"], p["b"]}) for p in accept_pairs}
    gray_pairs = []

    for a, b in combinations(reps, 2):
        key = frozenset({a, b})
        if key in accepted_set or key in reject_pairs:
            continue
        if is_blocked(a, b):
            add_reject(a, b, 2, "blocked by structural guard")
            continue
        if not short_name_allowed(a, b, mention_counts, args.min_short_mentions):
            add_reject(a, b, 2, "short-name rule")
            continue

        cos = cosine(emb_map[a], emb_map[b])

        if cos >= args.auto_cos:
            add_accept((2, -cos, 0), a, b, "stage2-cos")
            log({"stage": 2, "entity_a": a, "entity_b": b, "cosine": cos,
                 "decision": "candidate", "reason": f"cosine >= {args.auto_cos}"})
            continue

        # Typo promotion to gray (LLM will see it)
        promoted = False
        if a[0].casefold() == b[0].casefold() and len(a) > 3:
            lev = levenshtein(a.casefold(), b.casefold())
            if lev <= 2:
                gray_pairs.append((a, b, cos, f"typo (Levenshtein {lev})"))
                log({"stage": 2, "entity_a": a, "entity_b": b, "cosine": cos,
                     "decision": "gray", "reason": f"typo (Levenshtein {lev})"})
                promoted = True

        if promoted:
            continue

        if cos >= args.gray_min:
            gray_pairs.append((a, b, cos, f"cosine in [{args.gray_min}, {args.auto_cos})"))
            log({"stage": 2, "entity_a": a, "entity_b": b, "cosine": cos,
                 "decision": "gray", "reason": f"cosine in [{args.gray_min}, {args.auto_cos})"})
        else:
            add_reject(a, b, 2, f"cosine < {args.gray_min}", {"cosine": cos})

    print(f"Stage 2: {len(gray_pairs)} gray-zone pairs")

    # Stage 3: two-way LLM verification
    for a, b, cos, reason in gray_pairs:
        if is_blocked(a, b):
            add_reject(a, b, 3, "blocked by structural guard", {"cosine": cos})
            continue
        if not short_name_allowed(a, b, mention_counts, args.min_short_mentions):
            add_reject(a, b, 3, "short-name rule", {"cosine": cos})
            continue

        ok, detail = llm_verify(a, b, args.llm_url, args.llm_model)
        if ok:
            add_accept((2, -cos, 1), a, b, "stage3-llm")
            log({"stage": 3, "entity_a": a, "entity_b": b, "cosine": cos,
                 "decision": "candidate", "reason": f"llm: {detail}"})
        else:
            add_reject(a, b, 3, f"llm: {detail}", {"cosine": cos})

    print("Stage 3 complete")

    # ------------------------------------------------------------------
    # Pass 2: apply merges strongest-first with cannot-link checking
    # ------------------------------------------------------------------
    accept_pairs.sort(key=lambda p: p["sort_key"])

    dsu = DSU(entities)
    component_members = {e: {e} for e in entities}

    applied = 0
    refused = 0
    for p in accept_pairs:
        a, b, source = p["a"], p["b"], p["source"]
        ca, cb = dsu.find(a), dsu.find(b)
        if ca == cb:
            continue

        ma = component_members.get(ca, {a})
        mb = component_members.get(cb, {b})

        conflict = None
        for x in ma:
            for y in mb:
                if frozenset({x, y}) in reject_pairs:
                    conflict = (x, y)
                    break
            if conflict:
                break

        if conflict:
            log({"stage": 3.5, "entity_a": a, "entity_b": b,
                 "decision": "skip", "source": source,
                 "reason": f"cannot-link: {conflict[0]} <-> {conflict[1]}"})
            refused += 1
            continue

        dsu.union(a, b)
        new_root = dsu.find(a)
        component_members[new_root] = ma | mb
        if ca != new_root:
            component_members.pop(ca, None)
        if cb != new_root:
            component_members.pop(cb, None)
        applied += 1
        log({"stage": "apply", "entity_a": a, "entity_b": b,
             "decision": "merge", "source": source})

    print(f"Applied {applied} unions; refused {refused} via cannot-link")

    # ------------------------------------------------------------------
    # Stage 4: apply merges to LightRAG
    # ------------------------------------------------------------------
    comps = [g for g in dsu.groups() if len(g) > 1]
    print(f"components to merge: {len(comps)}")

    total_merged_away = 0
    for comp in comps:
        target = canonical(comp, mention_counts)
        sources = [x for x in comp if x != target]
        total_merged_away += len(sources)
        merge_entities(sources, target, args.lightrag_url, dry_run=args.dry_run)
        log({"stage": 4, "entities_to_change": sources,
             "entity_to_change_into": target,
             "decision": "merge", "reason": "component"})

    logf.close()
    print(f"done; {total_merged_away} entities absorbed into {len(comps)} targets")
    print(f"decisions logged to {args.log}")


if __name__ == "__main__":
    main()
