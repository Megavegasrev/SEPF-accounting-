import "server-only";
import { runUser, one, newKey } from "@/services/_run";
import {
  salaryProfileSchema, salaryAdvanceRequestSchema, salaryAdvancePaySchema, salaryBalancePaySchema, openCycleSchema,
} from "@/lib/schemas";
import type { z } from "zod";
import type {
  SalaryProfile, SalaryCycle, SalaryAdvanceRequest, SalaryBalancePayment, SalaryCycleSummary, UUID,
} from "@/lib/types";

export async function setSalaryProfile(actor: UUID, input: z.input<typeof salaryProfileSchema>): Promise<SalaryProfile> {
  const v = salaryProfileSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<SalaryProfile[]>`
    select * from set_salary_profile(${v.user_id}, ${v.salary_eligible}, ${v.monthly_salary},
      ${v.can_request_advance}, ${v.advance_ceiling}, ${v.effective_date}, ${v.note ?? null})
  `));
}

export async function openSalaryCycle(actor: UUID, input: z.input<typeof openCycleSchema>): Promise<SalaryCycle> {
  const v = openCycleSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<SalaryCycle[]>`
    select * from open_salary_cycle(${v.user_id}, ${v.period})
  `));
}

export async function requestSalaryAdvance(actor: UUID, input: z.input<typeof salaryAdvanceRequestSchema>): Promise<SalaryAdvanceRequest> {
  const v = salaryAdvanceRequestSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<SalaryAdvanceRequest[]>`
    select * from request_salary_advance(${v.period}, ${v.amount})
  `));
}

export async function paySalaryAdvance(actor: UUID, input: z.input<typeof salaryAdvancePaySchema>): Promise<unknown> {
  const v = salaryAdvancePaySchema.parse(input);
  const key = v.idempotency_key ?? newKey();
  return runUser(actor, async (tx) => one(await tx`
    select * from pay_salary_advance(${v.request_id}, ${key})
  `));
}

export async function paySalaryBalance(actor: UUID, input: z.input<typeof salaryBalancePaySchema>): Promise<SalaryBalancePayment> {
  const v = salaryBalancePaySchema.parse(input);
  const key = v.idempotency_key ?? newKey();
  return runUser(actor, async (tx) => one(await tx<SalaryBalancePayment[]>`
    select * from pay_salary_balance(${v.cycle_id}, ${key})
  `));
}

export async function getCycleSummary(actor: UUID, cycleId: UUID): Promise<SalaryCycleSummary | null> {
  return runUser(actor, async (tx) => {
    const [row] = await tx<SalaryCycleSummary[]>`select * from salary_cycle_summary where cycle_id = ${cycleId}`;
    return row ?? null;
  });
}

export async function listCycleSummaries(actor: UUID, userId?: UUID): Promise<SalaryCycleSummary[]> {
  return runUser(actor, (tx) => (userId
    ? tx<SalaryCycleSummary[]>`select * from salary_cycle_summary where user_id = ${userId} order by period desc`
    : tx<SalaryCycleSummary[]>`select * from salary_cycle_summary order by period desc`
  ).then((r) => [...r]));
}
