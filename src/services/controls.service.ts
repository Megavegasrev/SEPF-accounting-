import "server-only";
import { runUser, one } from "@/services/_run";
import { accountingControlSchema, attachmentMetaSchema, internalReceiptSchema } from "@/lib/schemas";
import type { z } from "zod";
import type { AccountingControl, Attachment, InternalReceipt, PaymentControlStatus, UUID } from "@/lib/types";

export async function recordAccountingControl(actor: UUID, input: z.input<typeof accountingControlSchema>): Promise<AccountingControl> {
  const v = accountingControlSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<AccountingControl[]>`
    select * from record_accounting_control(${v.payment_id}, ${v.decision}, ${v.cause ?? null}, ${v.comment ?? null})
  `));
}

/** Register supporting-document metadata (the file itself is in private storage). */
export async function addAttachment(actor: UUID, input: z.input<typeof attachmentMetaSchema>): Promise<Attachment> {
  const v = attachmentMetaSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<Attachment[]>`
    select * from add_attachment(${v.entity_type}, ${v.entity_id}, ${v.file_name}, ${v.mime_type},
      ${v.byte_size}, ${v.storage_path}, ${v.sha256})
  `));
}

export async function replaceAttachment(
  actor: UUID,
  oldId: UUID,
  input: Omit<z.input<typeof attachmentMetaSchema>, "entity_type" | "entity_id">,
): Promise<Attachment> {
  return runUser(actor, async (tx) => one(await tx<Attachment[]>`
    select * from replace_attachment(${oldId}, ${input.file_name}, ${input.mime_type},
      ${input.byte_size}, ${input.storage_path}, ${input.sha256})
  `));
}

export async function confirmInternalReceipt(actor: UUID, input: z.input<typeof internalReceiptSchema>): Promise<InternalReceipt> {
  const v = internalReceiptSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<InternalReceipt[]>`
    select * from confirm_internal_receipt(${v.payment_id}, ${v.status}, ${v.comment ?? null})
  `));
}

export async function getControlStatus(actor: UUID, paymentId: UUID): Promise<PaymentControlStatus | null> {
  return runUser(actor, async (tx) => {
    const [row] = await tx<PaymentControlStatus[]>`select * from payment_control_status where payment_id = ${paymentId}`;
    return row ?? null;
  });
}

/** Completed payments still awaiting an accounting control (Accountant dashboard). */
export async function listPaymentsAwaitingControl(actor: UUID): Promise<PaymentControlStatus[]> {
  return runUser(actor, (tx) => tx<PaymentControlStatus[]>`
    select * from payment_control_status where control_decision is null order by payment_id
  `.then((r) => [...r]));
}
