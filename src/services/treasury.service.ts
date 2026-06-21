import "server-only";
import { runUser, one, newKey } from "@/services/_run";
import { incomeSchema } from "@/lib/schemas";
import type { TreasuryBalance, TreasuryConsolidated, IncomeEntry, UUID } from "@/lib/types";
import type { z } from "zod";

export async function getBalances(actor: UUID): Promise<TreasuryBalance[]> {
  return runUser(actor, (tx) => tx<TreasuryBalance[]>`
    select * from treasury_balances order by code
  `.then((r) => [...r]));
}

export async function getConsolidated(actor: UUID): Promise<TreasuryConsolidated> {
  return runUser(actor, async (tx) => one(await tx<TreasuryConsolidated[]>`select * from treasury_consolidated`));
}

/**
 * Record ordinary treasury income (Cashier -> small, Accountant -> large).
 * Creates a structured income_entries row + a positive movement + audit log,
 * atomically and idempotently. Ordinary income only — capital contributions,
 * borrowings, loan repayments and transfers use their own dedicated services.
 */
export async function recordIncome(
  actor: UUID,
  input: z.input<typeof incomeSchema>,
  idempotencyKey?: string,
): Promise<IncomeEntry> {
  const v = incomeSchema.parse(input);
  const key = idempotencyKey ?? newKey();
  return runUser(actor, async (tx) => one(await tx<IncomeEntry[]>`
    select * from record_income(${v.account_id}, ${v.amount}, ${key},
      ${v.source_payer ?? null}, ${v.income_type ?? null}, ${v.purpose ?? null},
      ${v.operation_date ?? null}, ${v.payment_method ?? null},
      ${v.external_reference ?? null}, ${v.project ?? null})
  `));
}
