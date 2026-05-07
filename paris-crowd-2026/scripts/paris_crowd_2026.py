"""
Paris crowd-level estimator for April–June 2026.

The output is an estimate, not a measurement. There is no public dataset of
daily arrivals at CDG. The index combines:
  - CDG monthly passenger baseline (ADP press releases, 2025 actuals)
  - Day-of-week travel patterns
  - French public holidays + the 2025-2026 Paris (Zone C) school calendar
  - Recurring events (Roland-Garros 2026, Fête de la Musique, etc.)

Index scale: 0 (empty) – 100 (worst expected day in window).
"""
from __future__ import annotations

import csv
from dataclasses import dataclass, field
from datetime import date, timedelta
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

OUT_DIR = Path(__file__).resolve().parent.parent / "output"
OUT_DIR.mkdir(parents=True, exist_ok=True)

# CDG monthly passenger totals (millions, ADP 2025 actuals; Jun is the
# extrapolated trend used as a baseline scaler only).
MONTH_BASELINE = {4: 6.05, 5: 6.21, 6: 6.45}

DOW_FACTOR = {0: 0.92, 1: 0.90, 2: 0.95, 3: 1.00, 4: 1.10, 5: 1.08, 6: 1.05}

PUBLIC_HOLIDAYS = {
    date(2026, 4, 6): "復活節週一 (Lundi de Pâques)",
    date(2026, 5, 1): "勞動節 (Fête du Travail)",
    date(2026, 5, 8): "二戰勝利紀念日 (Victoire 1945)",
    date(2026, 5, 14): "耶穌升天節 (Ascension)",
    date(2026, 5, 25): "聖靈降臨節週一 (Lundi de Pentecôte)",
}

BRIDGE_DAYS = {
    date(2026, 5, 15): "5/14 升天節後的『搭橋日』",
    date(2026, 5, 18): "升天節週末延伸日 (Roland-Garros 資格賽首日)",
}

SCHOOL_SPRING_BREAK = (date(2026, 4, 18), date(2026, 5, 3))

ROLAND_GARROS_QUALIF = (date(2026, 5, 18), date(2026, 5, 23))
ROLAND_GARROS_MAIN = (date(2026, 5, 24), date(2026, 6, 7))
ROLAND_GARROS_FINALS = (date(2026, 6, 5), date(2026, 6, 7))

FETE_MUSIQUE = date(2026, 6, 21)


@dataclass
class DayScore:
    d: date
    base: float
    dow: float
    boost: float = 1.0
    events: list[str] = field(default_factory=list)

    @property
    def raw(self) -> float:
        return self.base * self.dow * self.boost


def in_range(d: date, span: tuple[date, date]) -> bool:
    return span[0] <= d <= span[1]


def build_day(d: date) -> DayScore:
    base = MONTH_BASELINE[d.month]
    dow = DOW_FACTOR[d.weekday()]
    score = DayScore(d=d, base=base, dow=dow)

    if d in PUBLIC_HOLIDAYS:
        score.boost *= 1.25
        score.events.append(f"國定假日：{PUBLIC_HOLIDAYS[d]}")

    if d in BRIDGE_DAYS:
        score.boost *= 1.30
        score.events.append(BRIDGE_DAYS[d])

    if in_range(d, SCHOOL_SPRING_BREAK):
        score.boost *= 1.12
        score.events.append("巴黎 (Zone C) 學校春假")

    # Easter weekend halo
    if d in (date(2026, 4, 4), date(2026, 4, 5)):
        score.boost *= 1.20
        score.events.append("復活節週末 (Pâques)")

    # Ascension long weekend halo (Thu 5/14 – Sun 5/17 effectively)
    if d in (date(2026, 5, 16), date(2026, 5, 17)):
        score.boost *= 1.20
        score.events.append("升天節 4 天連假週末")

    # Pentecôte weekend (Sat 5/23 – Sun 5/24)
    if d in (date(2026, 5, 23), date(2026, 5, 24)):
        score.boost *= 1.18
        score.events.append("聖靈降臨節週末")

    if in_range(d, ROLAND_GARROS_QUALIF):
        score.boost *= 1.08
        score.events.append("Roland-Garros 資格賽")

    if in_range(d, ROLAND_GARROS_MAIN):
        score.boost *= 1.15
        score.events.append("Roland-Garros 法網正賽")

    if in_range(d, ROLAND_GARROS_FINALS):
        score.boost *= 1.15
        score.events.append("Roland-Garros 決賽週末")

    if d == FETE_MUSIQUE:
        score.boost *= 1.30
        score.events.append("音樂節 Fête de la Musique (全城戶外演出)")
    if d in (FETE_MUSIQUE - timedelta(days=1), FETE_MUSIQUE + timedelta(days=1)):
        score.boost *= 1.08
        score.events.append("Fête de la Musique 前後")

    # 5/1 + 5/8 are both Fridays in 2026 → guaranteed long weekends
    if d in (date(2026, 5, 2), date(2026, 5, 3)):
        score.boost *= 1.15
        score.events.append("勞動節 4 天連假週末")
    if d in (date(2026, 5, 9), date(2026, 5, 10)):
        score.boost *= 1.15
        score.events.append("5/8 勝利日 4 天連假週末")

    return score


def label(idx: float) -> str:
    if idx >= 80:
        return "崩潰"
    if idx >= 65:
        return "很擠"
    if idx >= 50:
        return "偏多"
    if idx >= 35:
        return "尚可"
    return "舒適"


def main() -> None:
    days = []
    d = date(2026, 4, 1)
    end = date(2026, 6, 30)
    while d <= end:
        days.append(build_day(d))
        d += timedelta(days=1)

    raws = [s.raw for s in days]
    lo, hi = min(raws), max(raws)
    rows = []
    for s in days:
        idx = round(100 * (s.raw - lo) / (hi - lo), 1)
        rows.append(
            {
                "date": s.d.isoformat(),
                "weekday": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][s.d.weekday()],
                "month": s.d.month,
                "index": idx,
                "level": label(idx),
                "events": "; ".join(s.events) if s.events else "—",
            }
        )

    df = pd.DataFrame(rows)
    csv_path = OUT_DIR / "crowd_index_2026.csv"
    df.to_csv(csv_path, index=False, quoting=csv.QUOTE_MINIMAL)

    crash = df.sort_values("index", ascending=False).head(15)
    calm = df.sort_values("index", ascending=True).head(15)

    with open(OUT_DIR / "top_15_crash_days.md", "w", encoding="utf-8") as f:
        f.write("# 巴黎 2026 年 4-6 月：最崩潰的 15 天\n\n")
        f.write("| 日期 | 星期 | 指數 | 等級 | 主因 |\n|---|---|---|---|---|\n")
        for _, r in crash.iterrows():
            f.write(f"| {r['date']} | {r['weekday']} | {r['index']} | {r['level']} | {r['events']} |\n")

    with open(OUT_DIR / "top_15_calm_days.md", "w", encoding="utf-8") as f:
        f.write("# 巴黎 2026 年 4-6 月：最舒適的 15 天\n\n")
        f.write("| 日期 | 星期 | 指數 | 等級 | 備註 |\n|---|---|---|---|---|\n")
        for _, r in calm.iterrows():
            f.write(f"| {r['date']} | {r['weekday']} | {r['index']} | {r['level']} | {r['events']} |\n")

    fig, ax = plt.subplots(figsize=(16, 5))
    level_en = {"崩潰": "Brutal", "很擠": "Crowded", "偏多": "Busy", "尚可": "OK", "舒適": "Calm"}
    color_map = {"Brutal": "#b30000", "Crowded": "#e34a33", "Busy": "#fdae61", "OK": "#a6d96a", "Calm": "#1a9850"}
    colors = [color_map[level_en[r]] for r in df["level"]]
    ax.bar(range(len(df)), df["index"], color=colors)
    ax.set_xticks([i for i, r in enumerate(rows) if date.fromisoformat(r["date"]).day in (1, 8, 15, 22)])
    ax.set_xticklabels(
        [r["date"][5:] for r in rows if date.fromisoformat(r["date"]).day in (1, 8, 15, 22)],
        rotation=45,
        ha="right",
    )
    ax.set_ylabel("Crowd index (0=quiet, 100=worst)")
    ax.set_title("Paris crowd index — Apr–Jun 2026 (CDG-anchored estimate)")
    ax.axvline(29, color="grey", lw=0.5, ls="--")  # May 1
    ax.axvline(60, color="grey", lw=0.5, ls="--")  # Jun 1
    handles = [plt.Rectangle((0, 0), 1, 1, color=c) for c in color_map.values()]
    ax.legend(handles, color_map.keys(), loc="upper left", ncol=5, fontsize=8)
    fig.tight_layout()
    fig.savefig(OUT_DIR / "crowd_index_chart.png", dpi=130)

    print(f"Wrote {csv_path}")
    print(f"Wrote {OUT_DIR / 'top_15_crash_days.md'}")
    print(f"Wrote {OUT_DIR / 'top_15_calm_days.md'}")
    print(f"Wrote {OUT_DIR / 'crowd_index_chart.png'}")
    print()
    print("Top 5 崩潰日:")
    print(crash.head(5).to_string(index=False))
    print()
    print("Top 5 舒適日:")
    print(calm.head(5).to_string(index=False))


if __name__ == "__main__":
    main()
