/** The trip's shared purse: who paid what for whom, and who owes whom in the end. Pure arithmetic in cents. */

export interface Party {
  id: string;
  name: string;
  adults: number;
  children: number;
}

export type SplitMode = "equal" | "heads" | "custom";

export interface Expense {
  id: string;
  amountCents: number;
  paidBy: string;
  /** "equal": every party the same. "heads": by people, children weighted. "custom": by the given weights. */
  mode: SplitMode;
  /** The parties that share it; empty means everyone. */
  among: string[];
  /** For "custom": weight per party, for example the number of people who took part. */
  weights: Record<string, number>;
}

export interface Payment {
  from: string;
  to: string;
  amountCents: number;
}

/** Split an amount by weights so that the parts add up to the cent: the largest remainders get the spare cents. */
export function shares(amountCents: number, weights: Map<string, number>): Map<string, number> {
  const total = [...weights.values()].reduce((a, b) => a + b, 0);
  const out = new Map<string, number>();
  if (total <= 0) return out;
  const exact = [...weights].map(([id, w]) => ({ id, raw: (amountCents * w) / total }));
  let given = 0;
  for (const e of exact) {
    const part = Math.floor(e.raw);
    out.set(e.id, part);
    given += part;
  }
  const spare = exact.map((e) => ({ id: e.id, rest: e.raw - Math.floor(e.raw) })).sort((a, b) => b.rest - a.rest || a.id.localeCompare(b.id));
  for (let i = 0; i < amountCents - given; i++) out.set(spare[i % spare.length]!.id, out.get(spare[i % spare.length]!.id)! + 1);
  return out;
}

export function weightsFor(expense: Pick<Expense, "mode" | "among" | "weights">, parties: Party[], childWeight: number): Map<string, number> {
  const sharing = expense.among.length ? parties.filter((p) => expense.among.includes(p.id)) : parties;
  const w = new Map<string, number>();
  for (const p of sharing) {
    const weight = expense.mode === "custom" ? (expense.weights[p.id] ?? 0) : expense.mode === "heads" ? p.adults + p.children * childWeight : 1;
    if (weight > 0) w.set(p.id, weight);
  }
  return w;
}

export function settle(parties: Party[], expenses: Expense[], payments: Payment[], childWeight = 1) {
  const paid = new Map(parties.map((p) => [p.id, 0]));
  const owed = new Map(parties.map((p) => [p.id, 0]));
  const unsplit: string[] = [];
  for (const e of expenses) {
    const parts = shares(e.amountCents, weightsFor(e, parties, childWeight));
    // Nobody to share it with (party removed, all weights zero): it stays out of the reckoning and is reported.
    if (parts.size === 0 || !paid.has(e.paidBy)) {
      unsplit.push(e.id);
      continue;
    }
    paid.set(e.paidBy, paid.get(e.paidBy)! + e.amountCents);
    for (const [id, part] of parts) owed.set(id, (owed.get(id) ?? 0) + part);
  }
  // Positive: gets money back. Negative: still owes.
  const balance = new Map(parties.map((p) => [p.id, paid.get(p.id)! - owed.get(p.id)!]));
  for (const p of payments) {
    if (!balance.has(p.from) || !balance.has(p.to)) continue;
    balance.set(p.from, balance.get(p.from)! + p.amountCents);
    balance.set(p.to, balance.get(p.to)! - p.amountCents);
  }
  // Few transfers: the one who owes most pays the one who is owed most, until all is even.
  const debtors = [...balance].filter(([, b]) => b < 0).map(([id, b]) => ({ id, left: -b }));
  const creditors = [...balance].filter(([, b]) => b > 0).map(([id, b]) => ({ id, left: b }));
  const transfers: Payment[] = [];
  for (;;) {
    debtors.sort((a, b) => b.left - a.left || a.id.localeCompare(b.id));
    creditors.sort((a, b) => b.left - a.left || a.id.localeCompare(b.id));
    const d = debtors[0];
    const c = creditors[0];
    if (!d || !c || d.left === 0 || c.left === 0) break;
    const amount = Math.min(d.left, c.left);
    transfers.push({ from: d.id, to: c.id, amountCents: amount });
    d.left -= amount;
    c.left -= amount;
  }
  return {
    totalCents: expenses.filter((e) => !unsplit.includes(e.id)).reduce((a, e) => a + e.amountCents, 0),
    parties: parties.map((p) => ({ ...p, paidCents: paid.get(p.id)!, shareCents: owed.get(p.id)!, balanceCents: balance.get(p.id)! })),
    transfers,
    unsplit,
  };
}
