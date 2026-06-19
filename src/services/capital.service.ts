import "server-only";
import { runUser, one, newKey } from "@/services/_run";
import { capitalDeclareSchema, capitalConfirmSchema } from "@/lib/schemas";
import type { z } from "zod";
import type { CapitalContribution, ShareholderCapitalSummary, UUID } from "@/lib/types";

export async function declareContribution(actor: UUID, input: z.input<typeof capitalDeclareSchema>): Promise<CapitalContribution> {
  const v = capitalDeclareSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<CapitalContribution[]>`
    select * from declare_capital_contribution(${v.amount})
  `));
}

export async function confirmContribution(actor: UUID, input: z.input<typeof capitalConfirmSchema>): Promise<CapitalContribution> {
  const v = capitalConfirmSchema.parse(input);
  const key = v.idempotency_key ?? newKey();
  return runUser(actor, async (tx) => one(await tx<CapitalContribution[]>`
    select * from confirm_capital_contribution(${v.contribution_id}, ${v.confirmed}, ${key}, ${v.cause ?? null})
  `));
}

export async function listContributions(actor: UUID, shareholderId?: UUID): Promise<CapitalContribution[]> {
  return runUser(actor, (tx) => (shareholderId
    ? tx<CapitalContribution[]>`select * from capital_contributions where shareholder_user_id = ${shareholderId} order by declared_at desc`
    : tx<CapitalContribution[]>`select * from capital_contributions order by declared_at desc`
  ).then((r) => [...r]));
}

export async function getShareholderSummary(actor: UUID): Promise<ShareholderCapitalSummary[]> {
  return runUser(actor, (tx) => tx<ShareholderCapitalSummary[]>`
    select * from shareholder_capital_summary order by total_confirmed desc
  `.then((r) => [...r]));
}
