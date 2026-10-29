#!/usr/bin/env python3
"""Regenerates delay_stats.json and category.json. Independent of the Rust code.
Usage: python3 core/fixtures/gen_delay.py   (writes both files next to this script)
"""
import json, os

H = 3600
T0 = 1_800_000_000 // H * H  # an exact hour start

def row(ident, op, icao, status, sched, delay_min=None, field="actual"):
    r = {"ident": ident, "operator": op, "other_icao": icao, "status": status,
         "scheduled": sched, "estimated": None, "actual": None}
    if delay_min is not None and sched is not None:
        r[field] = sched + int(round(delay_min * 60))
    return r

def delay_sec(r):
    if r["scheduled"] is None: return None
    t = r["actual"] if r["actual"] is not None else r["estimated"]
    if t is None: return None
    return max(0, t - r["scheduled"])

def stats(rows):
    total = len(rows)
    buckets = {}
    on_time = delayed15 = canceled = 0
    sum_sec = n_avg = 0
    routes, airlines = {}, {}
    for r in rows:
        if r["scheduled"] is None: continue
        h = r["scheduled"] // H * H
        b = buckets.setdefault(h, {"hour": h, "onTime": 0, "late15": 0, "late45": 0, "canceled": 0, "diverted": 0})
        st = r["status"]
        if st == "canceled":
            b["canceled"] += 1; canceled += 1
            routes.setdefault(r["other_icao"], [0, 0])[1] += 1
            if r["operator"] is not None: airlines.setdefault(r["operator"], [0, 0])[1] += 1
            continue
        if st == "diverted":
            b["diverted"] += 1
            continue
        d = delay_sec(r)
        if d is not None:
            sum_sec += d; n_avg += 1
        if d is not None and d >= 45 * 60:
            b["late45"] += 1; delayed15 += 1; late = True
        elif d is not None and d >= 15 * 60:
            b["late15"] += 1; delayed15 += 1; late = True
        else:
            b["onTime"] += 1; on_time += 1; late = False
        if late:
            routes.setdefault(r["other_icao"], [0, 0])[0] += 1
            if r["operator"] is not None: airlines.setdefault(r["operator"], [0, 0])[0] += 1
    avg = sum_sec / n_avg / 60 if n_avg else 0.0
    if (n_avg and sum_sec >= 45 * 60 * n_avg) or canceled * 10 >= total and total > 0:
        sev = "major"
    elif n_avg and sum_sec >= 15 * 60 * n_avg:
        sev = "moderate"
    else:
        sev = "normal"
    def top(d, key):
        items = [(k, v) for k, v in d.items() if v[0] + v[1] > 0]
        items.sort(key=lambda kv: (-(kv[1][0] + kv[1][1]), kv[0]))
        return [{key: k, "delayed": v[0], "canceled": v[1]} for k, v in items[:5]]
    return {"total": total, "onTime": on_time, "delayed15": delayed15, "canceled": canceled,
            "avgDelayMinutes": avg,
            "perHour": [buckets[h] for h in sorted(buckets)],
            "worstRoutes": top(routes, "icao"), "worstAirlines": top(airlines, "operator"),
            "severity": sev}

cases = []
def add(name, rows): cases.append({"name": name, "rows": rows, "expected": stats(rows)})

# brief: 10 departures, 5 on time, 3 late 20, 1 late 50, 1 canceled
rows = []
for i in range(5): rows.append(row(f"AA{i}", "AAL", "KJFK", "departed", T0 + i * 600, 0))
for i in range(3): rows.append(row(f"BB{i}", "UAL", "KORD", "departed", T0 + 3600 + i * 600, 20))
rows.append(row("CC0", "DAL", "KATL", "departed", T0 + 3600 + 1800, 50))
rows.append(row("CC1", "DAL", "KATL", "canceled", T0 + 7200))
add("ten_departures", rows)
add("empty", [])
add("early_departure_counts_on_time", [row("E1", "AAL", "KJFK", "departed", T0, -12)])
add("estimated_used_without_actual", [row("E2", "AAL", "KJFK", "scheduled", T0, 30, "estimated")])
add("actual_wins_over_estimated", [dict(row("E3", "AAL", "KJFK", "landed", T0, 5), estimated=T0 + 3000)])
add("no_actual_or_estimated_not_in_average", [row("N1", "AAL", "KJFK", "scheduled", T0), row("N2", "AAL", "KJFK", "departed", T0, 30)])
add("boundary_899s_on_time_900s_late", [
    dict(row("B1", "AAL", "KJFK", "departed", T0), actual=T0 + 899),
    dict(row("B2", "AAL", "KJFK", "departed", T0), actual=T0 + 900)])
add("boundary_2699s_late15_2700s_late45", [
    dict(row("B3", "AAL", "KJFK", "departed", T0), actual=T0 + 2699),
    dict(row("B4", "AAL", "KJFK", "departed", T0), actual=T0 + 2700)])
add("unknown_status_string", [row("U1", "AAL", "KJFK", "holding", T0, 20)])
add("no_scheduled_counts_in_total_only", [row("S1", "AAL", "KJFK", "departed", None), row("S2", "AAL", "KJFK", "canceled", None), row("S3", "AAL", "KJFK", "departed", T0, 0)])
add("diverted_excluded_from_average", [row("D1", "AAL", "KJFK", "diverted", T0, 300), row("D2", "AAL", "KJFK", "departed", T0, 10)])
add("severity_normal", [row(f"N{i}", "AAL", "KJFK", "departed", T0, 5) for i in range(10)])
add("severity_moderate_avg_15", [row(f"M{i}", "AAL", "KJFK", "departed", T0, 15) for i in range(3)])
add("severity_moderate_avg_44", [row(f"M{i}", "AAL", "KJFK", "departed", T0, 44) for i in range(3)])
add("severity_major_avg_45", [row(f"J{i}", "AAL", "KJFK", "departed", T0, 45) for i in range(3)])
add("severity_major_cancel_10pct", [row("K0", "AAL", "KJFK", "canceled", T0)] + [row(f"K{i}", "AAL", "KJFK", "departed", T0, 0) for i in range(1, 10)])
add("severity_not_major_cancel_9pct", [row("K0", "AAL", "KJFK", "canceled", T0)] + [row(f"K{i}", "AAL", "KJFK", "departed", T0, 0) for i in range(1, 11)])
add("per_hour_sorted_and_flooring", [row("H3", "AAL", "KJFK", "departed", T0 + 3 * H + 5, 0), row("H1", "AAL", "KJFK", "departed", T0 + 59, 0), row("H2", "AAL", "KJFK", "departed", T0 + H + 3599, 20)])
rows = []
for k, (icao, n) in enumerate([("KAAA", 1), ("KBBB", 3), ("KCCC", 2), ("KDDD", 3), ("KEEE", 2), ("KFFF", 1), ("KGGG", 4)]):
    for j in range(n): rows.append(row(f"R{k}{j}", f"OP{k}", icao, "departed", T0, 20))
rows.append(row("R_none", None, "KZZZ", "departed", T0, 20))
rows.append(row("R_ok", "OPOK", "KOKK", "departed", T0, 0))
add("worst_lists_top5_ties_by_name", rows)

meta = {
    "generator": "core/fixtures/gen_delay.py",
    "rules": {
        "on_time_delay_minutes_lt": 15, "late45_delay_minutes_gte": 45,
        "severity_major_avg_minutes_gte": 45, "severity_major_cancel_pct_gte": 10,
        "severity_moderate_avg_minutes_gte": 15,
        "negative_delay_floors_at": 0, "worst_list_len": 5, "hour_seconds": 3600,
        "avg_delay_tolerance": 1e-9,
    },
    "invariants": {
        "delay": "(actual else estimated) minus scheduled, floored at 0",
        "total": "every row, including rows without scheduled",
        "rows_without_scheduled": "counted in total only",
        "per_hour": "one bucket per UTC clock hour with a scheduled row, ascending",
        "avg_delay_minutes": "mean over non-canceled, non-diverted rows with scheduled and a delay source; 0.0 if none",
        "worst_lists": "top 5 by delayed + canceled, ties by icao / operator ascending, entries with sum > 0 only; rows without operator skipped in airlines",
        "diverted": "per_hour.diverted only, not in canceled or average",
    },
}
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "delay_stats.json"), "w") as f:
    json.dump({"meta": meta, "cases": cases}, f, indent=2); f.write("\n")

# ---- flight category ----
def cat(ceil, vis):
    if vis < 0: return "LIFR"  # negative (or non-finite) visibility is invalid: treat as worst case
    c = float("inf") if ceil is None else ceil
    if c < 500 or vis < 1: return "LIFR"
    if c < 1000 or vis < 3: return "IFR"
    if c <= 3000 or vis <= 5: return "MVFR"
    return "VFR"

pts = [("clear_unlimited", None, 10), ("ceiling_800", 800, 10), ("ceiling_2500", 2500, 10), ("lifr_300_half_mile", 300, 0.5),
       ("ceiling_1000_vis_3", 1000, 3), ("ceiling_499", 499, 10), ("ceiling_500", 500, 10), ("ceiling_999", 999, 10),
       ("ceiling_3000", 3000, 10), ("ceiling_3001", 3001, 10), ("vis_0_99", None, 0.99), ("vis_1", None, 1),
       ("vis_2_99", None, 2.99), ("vis_3", None, 3), ("vis_5", None, 5), ("vis_5_01", None, 5.01),
       ("high_ceiling_low_vis", 10000, 0.25), ("zero_ceiling", 0, 10),
       ("negative_visibility", None, -1)]
cmeta = {"generator": "core/fixtures/gen_delay.py",
         "rules": {"lifr": "ceiling < 500 ft or visibility < 1 sm", "ifr": "ceiling < 1000 ft or visibility < 3 sm",
                   "mvfr": "ceiling 1000 to 3000 ft inclusive or visibility 3 to 5 sm inclusive", "vfr": "otherwise",
                   "missing_ceiling": "unlimited",
                   "invalid_visibility": "negative or non-finite (NaN, infinity) visibility is LIFR"}}
with open(os.path.join(here, "category.json"), "w") as f:
    json.dump({"meta": cmeta, "cases": [{"name": n, "ceiling_ft": c, "visibility_sm": v, "expected": cat(c, v)} for n, c, v in pts]}, f, indent=2); f.write("\n")
