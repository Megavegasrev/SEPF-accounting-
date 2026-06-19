import { describe, it, expect } from "vitest";
import * as treasury from "@/services/treasury.service";
import { USERS } from "../setup/testdb";

describe("treasury.service", () => {
  it("returns consolidated balances as numbers, with the conservation invariant", async () => {
    const c = await treasury.getConsolidated(USERS.super);
    expect(typeof c.total_treasury).toBe("number"); // numeric parsed to JS number
    expect(c.total_treasury).toBe(c.small_treasury + c.large_treasury + c.funds_in_transit);
  });

  it("enforces RLS through the service layer: the Cashier sees only small + transit", async () => {
    const cashierRows = await treasury.getBalances(USERS.cashier);
    const codes = cashierRows.map((r) => r.code).sort();
    expect(codes).not.toContain("LARGE");
    expect(codes).toContain("SMALL");

    const superRows = await treasury.getBalances(USERS.super);
    expect(superRows.map((r) => r.code)).toContain("LARGE");

    // The Cashier's consolidated view cannot see the large treasury.
    const cashierConsolidated = await treasury.getConsolidated(USERS.cashier);
    expect(cashierConsolidated.large_treasury).toBe(0);
  });
});
