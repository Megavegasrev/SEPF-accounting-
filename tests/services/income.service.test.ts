import { describe, it, expect } from "vitest";
import * as treasury from "@/services/treasury.service";
import { sql } from "@/db/client";
import { USERS } from "../setup/testdb";

async function accountId(code: string): Promise<string> {
  const rows = await sql<{ id: string }[]>`select id from treasury_accounts where code = ${code}`;
  return rows[0]!.id;
}
async function smallBalance(): Promise<number> {
  const rows = await treasury.getBalances(USERS.accountant);
  return rows.find((r) => r.code === "SMALL")!.balance;
}
async function specializedCounts() {
  const [r] = await sql<{ cap: number; loans: number; borrow: number; transfers: number }[]>`
    select (select count(*) from capital_contributions)::int as cap,
           (select count(*) from loans_granted)::int as loans,
           (select count(*) from company_borrowings)::int as borrow,
           (select count(*) from internal_transfers)::int as transfers`;
  return r!;
}

describe("income.service (ordinary incoming money)", () => {
  it("Cashier records small-treasury income; balance rises; specialized tables untouched", async () => {
    const small = await accountId("SMALL");
    const before = await smallBalance();
    const beforeCounts = await specializedCounts();

    const entry = await treasury.recordIncome(USERS.cashier, {
      account_id: small, amount: 12_345, source_payer: "Client A", income_type: "vente",
      purpose: "Vente", payment_method: "especes", external_reference: "R-1",
    });
    expect(entry.amount).toBe(12_345);
    expect(entry.movement_id).toBeTruthy();
    expect(await smallBalance()).toBe(before + 12_345);

    const afterCounts = await specializedCounts();
    expect(afterCounts).toEqual(beforeCounts); // income created no capital/loan/borrowing/transfer
  });

  it("is idempotent on the supplied key (no second movement)", async () => {
    const small = await accountId("SMALL");
    const before = await smallBalance();
    const input = { account_id: small, amount: 5_000, source_payer: "Client B" };
    const a = await treasury.recordIncome(USERS.cashier, input, "inc-svc-dup");
    const b = await treasury.recordIncome(USERS.cashier, input, "inc-svc-dup");
    expect(b.id).toBe(a.id);
    expect(await smallBalance()).toBe(before + 5_000); // counted once
  });

  it("Accountant records large-treasury income; Cashier cannot, Operations Director cannot", async () => {
    const large = await accountId("LARGE");
    const small = await accountId("SMALL");
    const entry = await treasury.recordIncome(USERS.accountant, { account_id: large, amount: 8_000, source_payer: "Subvention" });
    expect(entry.amount).toBe(8_000);

    await expect(treasury.recordIncome(USERS.cashier, { account_id: large, amount: 1_000 }))
      .rejects.toMatchObject({ message: /autoris/i });
    await expect(treasury.recordIncome(USERS.ops, { account_id: small, amount: 1_000 }))
      .rejects.toMatchObject({ message: /autoris/i });
  });
});
