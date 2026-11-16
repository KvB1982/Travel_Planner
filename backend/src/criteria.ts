import { CRITERIA, type Comparable } from "./compare.js";

/** What a trip can ask of an advert: every comparison row with a direction. */
export const MEASURABLE = CRITERIA.filter((c) => c.better !== null && c.group !== "votes").map((c) => ({
  key: c.key,
  label: c.label,
  group: c.group,
  format: c.format,
  /** "min": at least the target. "max": at most the target. "yes": has to be there, no target needed. */
  rule: c.better === "higher" ? ("min" as const) : c.better === "lower" ? ("max" as const) : ("yes" as const),
}));

export interface TripCriterion {
  id: string;
  /** A measurable key, or "custom" for something only people can judge ("ruhige Lage"). */
  key: string;
  label: string | null;
  level: "must" | "wish";
  target: number | null;
}

export type Verdict = "met" | "missed" | "unknown";
export type Checks = Record<string, "met" | "missed">;

export function judge(criteria: TripCriterion[], candidate: Comparable, checks: Checks) {
  const results = criteria.map((c) => {
    const known = CRITERIA.find((x) => x.key === c.key);
    const measurable = MEASURABLE.find((x) => x.key === c.key);
    const value = known ? known.value(candidate) : null;
    let status: Verdict = "unknown";
    if (measurable && value !== null) {
      if (measurable.rule === "yes") status = value === true ? "met" : "missed";
      else if (typeof value === "number" && c.target !== null) status = (measurable.rule === "min" ? value >= c.target : value <= c.target) ? "met" : "missed";
    }
    // What somebody checked by hand outweighs what the advert said or left open.
    const manual = checks[c.id] ?? null;
    return { id: c.id, key: c.key, label: c.label ?? measurable?.label ?? c.key, level: c.level, rule: measurable?.rule ?? null, format: measurable?.format ?? null, target: c.target, value, status: manual ?? status, manual: manual !== null };
  });
  const of = (level: "must" | "wish", status: Verdict) => results.filter((r) => r.level === level && r.status === status).length;
  const light =
    results.length === 0 ? null : of("must", "missed") > 0 ? ("red" as const) : of("must", "unknown") > 0 || of("wish", "missed") > 0 || of("wish", "unknown") > 0 ? ("yellow" as const) : ("green" as const);
  return {
    light,
    must: { met: of("must", "met"), missed: of("must", "missed"), unknown: of("must", "unknown") },
    wish: { met: of("wish", "met"), missed: of("wish", "missed"), unknown: of("wish", "unknown") },
    results,
  };
}
