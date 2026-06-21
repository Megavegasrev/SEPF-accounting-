import "server-only";
import { runUser, one, newKey } from "@/services/_run";
import {
  borrowingEnterSchema, borrowingConfirmSchema, borrowingRepaymentRequestSchema, borrowingRepaymentPaySchema,
} from "@/lib/schemas";
import type { z } from "zod";
import type { CompanyBorrowing, BorrowingInstallment, BorrowingSummary, UUID } from "@/lib/types";

export async function enterBorrowing(actor: UUID, input: z.input<typeof borrowingEnterSchema>): Promise<CompanyBorrowing> {
  const v = borrowingEnterSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<CompanyBorrowing[]>`
    select * from enter_borrowing(${v.lender_name}, ${v.principal})
  `));
}

export async function confirmReceipt(actor: UUID, input: z.input<typeof borrowingConfirmSchema>): Promise<CompanyBorrowing> {
  const v = borrowingConfirmSchema.parse(input);
  const key = v.idempotency_key ?? newKey();
  return runUser(actor, async (tx) => one(await tx<CompanyBorrowing[]>`
    select * from confirm_borrowing_receipt(${v.borrowing_id}, ${v.confirmed}, ${key}, ${v.cause ?? null})
  `));
}

export async function requestRepayment(actor: UUID, input: z.input<typeof borrowingRepaymentRequestSchema>): Promise<BorrowingInstallment> {
  const v = borrowingRepaymentRequestSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<BorrowingInstallment[]>`
    select * from request_borrowing_repayment(${v.borrowing_id}, ${v.principal_part}, ${v.interest_part},
      ${v.charges_part}, ${v.installment_number ?? null}, ${v.due_date ?? null})
  `));
}

export async function payRepayment(actor: UUID, input: z.input<typeof borrowingRepaymentPaySchema>): Promise<BorrowingInstallment> {
  const v = borrowingRepaymentPaySchema.parse(input);
  const key = v.idempotency_key ?? newKey();
  return runUser(actor, async (tx) => one(await tx<BorrowingInstallment[]>`
    select * from pay_borrowing_repayment(${v.request_id}, ${key})
  `));
}

export async function listBorrowings(actor: UUID): Promise<BorrowingSummary[]> {
  return runUser(actor, (tx) => tx<BorrowingSummary[]>`select * from borrowing_summary order by entered_at desc`.then((r) => [...r]));
}
