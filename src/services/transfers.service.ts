import "server-only";
import { runUser, one, newKey } from "@/services/_run";
import { transferInitiateSchema, transferConfirmSchema, transferCancelSchema } from "@/lib/schemas";
import type { z } from "zod";
import type { InternalTransfer, UUID } from "@/lib/types";

export async function initiateTransfer(actor: UUID, input: z.input<typeof transferInitiateSchema>): Promise<InternalTransfer> {
  const v = transferInitiateSchema.parse(input);
  const key = v.idempotency_key ?? newKey();
  return runUser(actor, async (tx) => one(await tx<InternalTransfer[]>`
    select * from initiate_transfer(${v.direction}, ${v.amount}, ${key})
  `));
}

export async function confirmTransfer(actor: UUID, input: z.input<typeof transferConfirmSchema>): Promise<InternalTransfer> {
  const v = transferConfirmSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<InternalTransfer[]>`
    select * from confirm_transfer(${v.transfer_id})
  `));
}

export async function cancelTransfer(actor: UUID, input: z.input<typeof transferCancelSchema>): Promise<InternalTransfer> {
  const v = transferCancelSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<InternalTransfer[]>`
    select * from cancel_transfer(${v.transfer_id}, ${v.reason})
  `));
}

export async function listTransfers(actor: UUID, status?: InternalTransfer["status"]): Promise<InternalTransfer[]> {
  return runUser(actor, (tx) => (status
    ? tx<InternalTransfer[]>`select * from internal_transfers where status = ${status} order by initiated_at desc`
    : tx<InternalTransfer[]>`select * from internal_transfers order by initiated_at desc`
  ).then((r) => [...r]));
}
