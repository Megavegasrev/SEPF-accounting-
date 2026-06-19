import "server-only";
import { runUser, one, newKey } from "@/services/_run";
import { investmentCreateSchema, investmentPaySchema } from "@/lib/schemas";
import type { z } from "zod";
import type { Investment, Asset, AssetRegister, UUID } from "@/lib/types";

export async function createInvestment(actor: UUID, input: z.input<typeof investmentCreateSchema>): Promise<Investment> {
  const v = investmentCreateSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<Investment[]>`
    select * from create_investment(${v.amount}, ${v.supplier}, ${v.asset_name}, ${v.asset_category},
      ${v.custodian_user_id ?? null}, ${v.custodian_name ?? null}, ${v.project ?? null})
  `));
}

export async function payInvestment(actor: UUID, input: z.input<typeof investmentPaySchema>): Promise<Asset> {
  const v = investmentPaySchema.parse(input);
  const key = v.idempotency_key ?? newKey();
  return runUser(actor, async (tx) => one(await tx<Asset[]>`
    select * from pay_investment(${v.request_id}, ${key}, ${v.acquired_on ?? null})
  `));
}

export async function listAssets(actor: UUID): Promise<AssetRegister[]> {
  return runUser(actor, (tx) => tx<AssetRegister[]>`
    select * from asset_register order by acquired_on desc
  `.then((r) => [...r]));
}
