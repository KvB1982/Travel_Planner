import { describe, expect, it } from "vitest";
import { settle, shares, type Expense, type Party } from "../src/ledger.js";

const A: Party = { id: "a", name: "A", adults: 2, children: 2 };
const B: Party = { id: "b", name: "B", adults: 2, children: 0 };
const C: Party = { id: "c", name: "C", adults: 1, children: 0 };
const e = (x: Partial<Expense> & Pick<Expense, "id" | "amountCents" | "paidBy">): Expense => ({ mode: "equal", among: [], weights: {}, ...x });

describe("ledger", () => {
  it("splits to the cent", () => {
    const parts = shares(1000, new Map([["a", 1], ["b", 1], ["c", 1]]));
    expect([...parts.values()].reduce((x, y) => x + y, 0)).toBe(1000);
    expect([...parts.values()].sort()).toEqual([333, 333, 334]);
  });

  it("shares equally between households by default and settles with few transfers", () => {
    const r = settle([A, B, C], [e({ id: "1", amountCents: 30000, paidBy: "a" }), e({ id: "2", amountCents: 6000, paidBy: "b" })], []);
    expect(r.totalCents).toBe(36000);
    expect(r.parties.map((p) => p.balanceCents)).toEqual([18000, -6000, -12000]);
    expect(r.transfers).toEqual([{ from: "c", to: "a", amountCents: 12000 }, { from: "b", to: "a", amountCents: 6000 }]);
  });

  it("can count heads with children at half, share among some only, and use weights", () => {
    const heads = settle([A, B], [e({ id: "1", amountCents: 10000, paidBy: "b", mode: "heads" })], [], 0.5);
    expect(heads.parties.map((p) => p.shareCents)).toEqual([6000, 4000]);
    const some = settle([A, B, C], [e({ id: "1", amountCents: 9000, paidBy: "a", among: ["a", "b"] })], []);
    expect(some.parties.map((p) => p.shareCents)).toEqual([4500, 4500, 0]);
    // A women's day out: one person each from A and B, two tickets paid by B.
    const custom = settle([A, B, C], [e({ id: "1", amountCents: 8000, paidBy: "b", mode: "custom", weights: { a: 1, b: 1 } })], []);
    expect(custom.transfers).toEqual([{ from: "a", to: "b", amountCents: 4000 }]);
  });

  it("takes payments already made into account and reports what cannot be shared", () => {
    const r = settle([A, B], [e({ id: "1", amountCents: 10000, paidBy: "a" }), e({ id: "2", amountCents: 500, paidBy: "gone" })], [{ from: "b", to: "a", amountCents: 5000 }]);
    expect(r.transfers).toEqual([]);
    expect(r.unsplit).toEqual(["2"]);
    expect(r.totalCents).toBe(10000);
  });
});
