import "server-only";
import { runUser, one, newKey } from "@/services/_run";
import { incomeSchema } from "@/lib/schemas";
import type { TreasuryBalance, TreasuryConsolidated, TreasuryMovement, UUID } from "@/lib/types";
import type { z } from "zod";

export async function getBalances(actor: UUID): Promise<TreasuryBalance[]> {
  return runUser(actor, (tx) => tx<TreasuryBalance[]>`
    select * from treasury_balances order by code
  `.then((r) => [...r]));
}

export async function getConsolidated(actor: UUID): Promise<TreasuryConsolidated> {
  return runUser(actor, async (tx) => one(await tx<TreasuryConsolidated[]>`select * from treasury_consolidated`));
}

/** Record treasury income (Cashier -> small, Accountant -> large). */
export async function recordIncome(
  actor: UUID,
  input: z.input<typeof incomeSchema>,
): Promise<TreasuryMovement> {
  const v = incomeSchema.parse(input);
  const key = newKey();
  return runUser(actor, async (tx) => one(await tx<TreasuryMovement[]>`
    select * from record_income(${v.account_id}, ${v.amount}, ${key}, ${v.memo ?? null}, ${v.source_id ?? null})
  `));
}
