import "server-only";
import { runUser, one, newKey } from "@/services/_run";
import { loanRequestSchema, loanDisburseSchema, loanInstallmentSchema, loanRepaymentSchema } from "@/lib/schemas";
import type { z } from "zod";
import type { LoanGranted, LoanRepayment, LoanSummary, UUID } from "@/lib/types";

export async function createLoanRequest(actor: UUID, input: z.input<typeof loanRequestSchema>): Promise<LoanGranted> {
  const v = loanRequestSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<LoanGranted[]>`
    select * from create_loan_request(${v.amount}, ${v.borrower_name}, ${v.purpose ?? "Loan granted"}, ${v.project ?? null})
  `));
}

export async function disburseLoan(actor: UUID, input: z.input<typeof loanDisburseSchema>): Promise<LoanGranted> {
  const v = loanDisburseSchema.parse(input);
  const key = v.idempotency_key ?? newKey();
  return runUser(actor, async (tx) => one(await tx<LoanGranted[]>`
    select * from disburse_loan(${v.request_id}, ${key})
  `));
}

export async function addInstallment(actor: UUID, input: z.input<typeof loanInstallmentSchema>): Promise<LoanRepayment> {
  const v = loanInstallmentSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<LoanRepayment[]>`
    select * from add_loan_installment(${v.loan_id}, ${v.amount}, ${v.due_date})
  `));
}

export async function recordRepayment(actor: UUID, input: z.input<typeof loanRepaymentSchema>): Promise<LoanRepayment> {
  const v = loanRepaymentSchema.parse(input);
  const key = v.idempotency_key ?? newKey();
  return runUser(actor, async (tx) => one(await tx<LoanRepayment[]>`
    select * from record_loan_repayment(${v.installment_id}, ${key})
  `));
}

export async function listLoans(actor: UUID): Promise<LoanSummary[]> {
  return runUser(actor, (tx) => tx<LoanSummary[]>`select * from loan_summary order by borrower_name`.then((r) => [...r]));
}

export async function listLoanRepayments(actor: UUID, loanId: UUID): Promise<LoanRepayment[]> {
  return runUser(actor, (tx) => tx<LoanRepayment[]>`
    select * from loan_repayments where loan_id = ${loanId} order by created_at
  `.then((r) => [...r]));
}
