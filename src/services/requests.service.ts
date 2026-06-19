import "server-only";
import { runUser, one, newKey } from "@/services/_run";
import {
  createRequestSchema, correctionSchema, validationSchema, payRequestSchema, disburseAdvanceSchema,
} from "@/lib/schemas";
import type { z } from "zod";
import type {
  RequestRow, RequestVersion, RequestValidation, Payment, RequestOverview, PaymentControlStatus, UUID,
} from "@/lib/types";

export async function createRequest(actor: UUID, input: z.input<typeof createRequestSchema>): Promise<RequestRow> {
  const v = createRequestSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<RequestRow[]>`
    select * from create_request(${v.amount}, ${v.beneficiary_type}, ${v.purpose}, ${v.category},
      ${v.proposed_treasury}, ${v.beneficiary_user_id ?? null}, ${v.beneficiary_name ?? null},
      ${v.project ?? null}, ${v.urgency}, ${v.desired_date ?? null})
  `));
}

export async function createCorrection(actor: UUID, input: z.input<typeof correctionSchema>): Promise<RequestVersion> {
  const v = correctionSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<RequestVersion[]>`
    select * from create_request_correction(${v.request_id}, ${v.amount}, ${v.beneficiary_type}, ${v.purpose},
      ${v.category}, ${v.proposed_treasury}, ${v.beneficiary_user_id ?? null}, ${v.beneficiary_name ?? null},
      ${v.project ?? null}, ${v.urgency}, ${v.desired_date ?? null})
  `));
}

export async function recordFirstValidation(actor: UUID, input: z.input<typeof validationSchema>): Promise<RequestValidation> {
  const v = validationSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<RequestValidation[]>`
    select * from record_first_validation(${v.version_id}, ${v.decision}, ${v.comment ?? null})
  `));
}

export async function recordFinalValidation(actor: UUID, input: z.input<typeof validationSchema>): Promise<RequestValidation> {
  const v = validationSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<RequestValidation[]>`
    select * from record_final_validation(${v.version_id}, ${v.decision}, ${v.comment ?? null})
  `));
}

export async function payRequest(actor: UUID, input: z.input<typeof payRequestSchema>): Promise<Payment> {
  const v = payRequestSchema.parse(input);
  const key = v.idempotency_key ?? newKey();
  return runUser(actor, async (tx) => one(await tx<Payment[]>`
    select * from pay_request(${v.request_id}, ${key})
  `));
}

export async function disburseSmallAdvance(actor: UUID, input: z.input<typeof disburseAdvanceSchema>): Promise<Payment> {
  const v = disburseAdvanceSchema.parse(input);
  const key = v.idempotency_key ?? newKey();
  return runUser(actor, async (tx) => one(await tx<Payment[]>`
    select * from disburse_small_advance(${v.request_id}, ${key})
  `));
}

export async function listRequests(actor: UUID): Promise<RequestOverview[]> {
  return runUser(actor, (tx) => tx<RequestOverview[]>`
    select * from request_overview order by created_at desc
  `.then((r) => [...r]));
}

/** Full request file for the timeline: header, all versions, decisions, payment & control. */
export async function getRequestDetail(actor: UUID, requestId: UUID): Promise<{
  request: RequestRow; versions: RequestVersion[]; validations: RequestValidation[];
  payment: Payment | null; control: PaymentControlStatus | null;
} | null> {
  return runUser(actor, async (tx) => {
    const [request] = await tx<RequestRow[]>`select * from requests where id = ${requestId}`;
    if (!request) return null;
    const versions = await tx<RequestVersion[]>`
      select * from request_versions where request_id = ${requestId} order by version_number`;
    const validations = await tx<RequestValidation[]>`
      select v.* from request_validations v
      join request_versions rv on rv.id = v.request_version_id
      where rv.request_id = ${requestId} order by v.decided_at`;
    const [payment] = await tx<Payment[]>`select * from payments where request_id = ${requestId}`;
    const [control] = payment
      ? await tx<PaymentControlStatus[]>`select * from payment_control_status where payment_id = ${payment.id}`
      : [];
    return { request, versions: [...versions], validations: [...validations], payment: payment ?? null, control: control ?? null };
  });
}
