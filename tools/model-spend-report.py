#!/usr/bin/env python3
"""Per-model token spend report over the local Claude Code transcript corpus.

Scans ~/.claude/projects/**/*.jsonl for assistant message usage records and
reports (a) per-model totals across the retained window and (b) the top-N
sessions by total token spend for one model, each session tagged with a
work-class label derived from its tool-use histogram.

USAGE RECORDS ARE PER-STREAM SNAPSHOTS, NOT PER-TURN DELTAS: a session's
usage lines repeat as a turn streams, so summing them raw double- and
triple-counts. The fix is deduplication by `message.id`, scoped PER SESSION
(ids are not guaranteed unique across sessions) — every total below is
computed from the deduplicated set, never from the raw line count.

THE WINDOW IS THE CORPUS'S, NOT THE OFFICE'S: ~/.claude/projects retains a
few weeks of transcripts and no longer. A total here is a claim about
records still on disk, not about all work ever done, which is why the
window's own min/max timestamps are printed beside every total rather than
left implicit.

A model id that matches none of the four known families (a substring match
on "fable"/"opus"/"sonnet"/"haiku", case-insensitive — the same test the
Claude Code changelog uses to name a release family) is folded into an
"other" bucket for the per-model table; nothing is silently dropped.

The --model filter for the top-N view is the same substring test applied
directly to the raw model id, not a restricted enum — a filter value that
matches no session in the corpus is a valid, unsurprising outcome (an empty
table), not an error.
"""
import argparse
import glob
import json
import os
import sys
from collections import Counter, defaultdict

CORPUS_ROOT = os.path.expanduser("~/.claude/projects")
KNOWN_FAMILIES = ("fable", "opus", "sonnet", "haiku")

USAGE_FIELDS = (
    ("uncached_input", "input_tokens"),
    ("cache_read", "cache_read_input_tokens"),
    ("cache_creation", "cache_creation_input_tokens"),
    ("output", "output_tokens"),
)


def model_family(model_id):
    """Bucket a raw model id into one of the four known families, else 'other'."""
    if not model_id:
        return "other"
    lowered = model_id.lower()
    for family in KNOWN_FAMILIES:
        if family in lowered:
            return family
    return "other"


def classify_work(tool_counts):
    """Dominant work class from a session's tool-name histogram.

    Ported from the measurement prototype's heuristic: five named classes
    keyed on tool-name substrings/exact names, a session tagged with every
    class at or above 60% of the leading class's count (co-dominant work
    reads as co-dominant, not flattened to one label). A session with tool
    calls that fit none of the five falls to a Bash-dominant residual
    category when Bash itself dominates, else an explicit catch-all — never
    silently absorbed into one of the five named classes it did not earn.
    """
    if not tool_counts:
        return "keine-tool-nutzung"

    def has(*names):
        return sum(v for k, v in tool_counts.items() if k in names)

    def has_prefix(prefix):
        return sum(v for k, v in tool_counts.items() if k.lower().startswith(prefix))

    def has_substr(substr):
        return sum(v for k, v in tool_counts.items() if substr in k.lower())

    mail = has_prefix("mcp__thunderbird")
    gis = sum(
        v
        for k, v in tool_counts.items()
        if "qgis" in k.lower() or "pbs-gis" in k.lower() or "pbs_gis" in k.lower()
    )
    bau = has("Edit", "Write", "NotebookEdit")
    rech = has("Read", "Grep", "Glob")
    orch = has("Agent", "Task")
    bash = tool_counts.get("Bash", 0)

    tags = {
        "Mail": mail,
        "GIS": gis,
        "Bau": bau,
        "Recherche/Review": rech,
        "Orchestrierung": orch,
    }
    top = max(tags.values())
    if top == 0:
        if bash > 0:
            return "Bash-dominant(von_Heuristik_nicht_erfasst)"
        return "unklassifiziert(sonstige-tools)"
    dominant = sorted(k for k, v in tags.items() if v > 0 and v >= 0.6 * top)
    return "+".join(dominant)


def scan_corpus(root):
    """Walk every transcript once, returning per-session state and corpus stats.

    Each session's state carries: min/max timestamp, the deduplicated
    per-family usage totals, the raw model id -> usage totals (for the
    --model substring filter), the tool-use histogram, and the deduplicated
    assistant-turn count.
    """
    files = sorted(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True))

    sessions = {}
    stats = {
        "n_files": len(files),
        "n_lines": 0,
        "n_bad_json": 0,
        "n_assistant_lines": 0,
        "n_dupe_msg_lines": 0,
        "window_min_ts": None,
        "window_max_ts": None,
    }

    def get_session(sid, project_dir):
        s = sessions.get(sid)
        if s is None:
            s = {
                "project_dir": project_dir,
                "min_ts": None,
                "max_ts": None,
                "seen_msg_ids": set(),
                "family_usage": defaultdict(lambda: defaultdict(int)),
                "raw_model_usage": defaultdict(lambda: defaultdict(int)),
                "tool_counts": Counter(),
            }
            sessions[sid] = s
        return s

    for path in files:
        project_dir = os.path.basename(os.path.dirname(path))
        try:
            fh = open(path, "r", encoding="utf-8", errors="replace")
        except OSError as exc:
            print(f"model-spend-report: cannot open {path}: {exc}", file=sys.stderr)
            continue
        with fh:
            for line in fh:
                stats["n_lines"] += 1
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    stats["n_bad_json"] += 1
                    continue
                if record.get("type") != "assistant":
                    continue
                sid = record.get("sessionId") or record.get("session_id")
                if not sid:
                    continue
                stats["n_assistant_lines"] += 1
                message = record.get("message") or {}
                mid = message.get("id")
                s = get_session(sid, project_dir)

                ts = record.get("timestamp")
                if ts:
                    if s["min_ts"] is None or ts < s["min_ts"]:
                        s["min_ts"] = ts
                    if s["max_ts"] is None or ts > s["max_ts"]:
                        s["max_ts"] = ts
                    if stats["window_min_ts"] is None or ts < stats["window_min_ts"]:
                        stats["window_min_ts"] = ts
                    if stats["window_max_ts"] is None or ts > stats["window_max_ts"]:
                        stats["window_max_ts"] = ts

                if mid and mid in s["seen_msg_ids"]:
                    stats["n_dupe_msg_lines"] += 1
                    continue
                if mid:
                    s["seen_msg_ids"].add(mid)

                model_id = message.get("model") or ""
                family = model_family(model_id)
                usage = message.get("usage") or {}
                for out_key, usage_key in USAGE_FIELDS:
                    n = usage.get(usage_key) or 0
                    s["family_usage"][family][out_key] += n
                    if model_id:
                        s["raw_model_usage"][model_id][out_key] += n

                content = message.get("content")
                if isinstance(content, list):
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "tool_use":
                            s["tool_counts"][c.get("name") or "?"] += 1

    return sessions, stats


def usage_total(usage_dict):
    return sum(usage_dict.get(k, 0) for k, _ in USAGE_FIELDS)


def build_model_totals(sessions):
    totals = defaultdict(lambda: defaultdict(int))
    for s in sessions.values():
        for family, usage in s["family_usage"].items():
            for out_key, _ in USAGE_FIELDS:
                totals[family][out_key] += usage.get(out_key, 0)
    return totals


def build_top_sessions(sessions, model_filter, top_n):
    needle = model_filter.lower()
    rows = []
    for sid, s in sessions.items():
        matched = defaultdict(int)
        for raw_model, usage in s["raw_model_usage"].items():
            if needle in raw_model.lower():
                for out_key, _ in USAGE_FIELDS:
                    matched[out_key] += usage.get(out_key, 0)
        total = usage_total(matched)
        if total == 0:
            continue
        rows.append(
            {
                "session_id": sid[:8],
                "session_id_full": sid,
                "project_dir": s["project_dir"],
                "date": (s["min_ts"] or "")[:10],
                "assistant_turns": len(s["seen_msg_ids"]),
                "total_tokens": total,
                "work_class": classify_work(s["tool_counts"]),
            }
        )
    rows.sort(key=lambda r: -r["total_tokens"])
    return rows[:top_n]


def fmt_int(n):
    return f"{n:,}"


def print_model_totals_table(totals, stats):
    families = list(KNOWN_FAMILIES) + ["other"]
    print(
        f"window: {stats['window_min_ts']} .. {stats['window_max_ts']}"
        f"  ({stats['n_files']} files, {stats['n_assistant_lines']} assistant lines,"
        f" {stats['n_dupe_msg_lines']} dupes deduped, {stats['n_bad_json']} bad-json lines)"
    )
    header = f"{'model':<10} {'uncached_in':>14} {'cache_read':>14} {'cache_creation':>14} {'output':>14} {'total':>16}"
    print(header)
    for family in families:
        usage = totals.get(family, {})
        total = usage_total(usage)
        print(
            f"{family:<10} "
            f"{fmt_int(usage.get('uncached_input', 0)):>14} "
            f"{fmt_int(usage.get('cache_read', 0)):>14} "
            f"{fmt_int(usage.get('cache_creation', 0)):>14} "
            f"{fmt_int(usage.get('output', 0)):>14} "
            f"{fmt_int(total):>16}"
        )


def print_top_sessions_table(rows, model_filter, top_n):
    print(f"\ntop {top_n} sessions matching model filter '{model_filter}':")
    if not rows:
        print("  (no sessions matched)")
        return
    header = f"{'session':<10} {'project_dir':<45} {'date':<11} {'turns':>6} {'total_tokens':>14}  work_class"
    print(header)
    for r in rows:
        print(
            f"{r['session_id']:<10} {r['project_dir']:<45} {r['date']:<11} "
            f"{r['assistant_turns']:>6} {fmt_int(r['total_tokens']):>14}  {r['work_class']}"
        )


def main():
    parser = argparse.ArgumentParser(
        description="Per-model token spend report over the local Claude Code transcript corpus."
    )
    parser.add_argument(
        "--model",
        default="fable",
        help="substring filter (case-insensitive) on the raw model id, for the top-N session view (default: fable)",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=10,
        help="number of sessions to show in the top-N view (default: 10)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit machine-readable JSON instead of tables",
    )
    args = parser.parse_args()

    sessions, stats = scan_corpus(CORPUS_ROOT)
    model_totals = build_model_totals(sessions)
    top_rows = build_top_sessions(sessions, args.model, args.top)

    if args.json:
        out = {
            "window_min_ts": stats["window_min_ts"],
            "window_max_ts": stats["window_max_ts"],
            "corpus": {
                "n_files": stats["n_files"],
                "n_lines": stats["n_lines"],
                "n_bad_json": stats["n_bad_json"],
                "n_assistant_lines": stats["n_assistant_lines"],
                "n_dupe_msg_lines": stats["n_dupe_msg_lines"],
            },
            "model_totals": {
                family: {
                    **{out_key: usage.get(out_key, 0) for out_key, _ in USAGE_FIELDS},
                    "total": usage_total(usage),
                }
                for family, usage in model_totals.items()
            },
            "top_sessions": {
                "model_filter": args.model,
                "top": args.top,
                "sessions": top_rows,
            },
        }
        print(json.dumps(out, indent=2, ensure_ascii=False))
        return 0

    print_model_totals_table(model_totals, stats)
    print_top_sessions_table(top_rows, args.model, args.top)
    return 0


if __name__ == "__main__":
    sys.exit(main())
