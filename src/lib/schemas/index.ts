import { z } from "zod";

/** Shared building blocks. FCFA amounts are positive integers (no decimals). */
const fcfa = z.coerce.number({ invalid_type_error: "Montant invalide." })
  .int("Le montant doit être un entier (FCFA, sans décimales).")
  .positive("Le montant doit être supérieur à zéro.");
const fcfa0 = z.coerce.number().int("Montant entier requis.").nonnegative("Le montant ne peut pas être négatif.");
const uuid = z.string().uuid("Identifiant invalide.");
const idem = z.string().min(1).max(200).optional();
const nonEmpty = (label: string) => z.string().trim().min(1, `${label} est obligatoire.`);
const treasury = z.enum(["small_treasury", "large_treasury"], { errorMap: () => ({ message: "Trésorerie invalide." }) });
const optDate = z.coerce.date().optional();

// ---- auth ------------------------------------------------------------------
export const loginSchema = z.object({
  email: z.string().trim().email("Adresse e-mail invalide."),
  password: z.string().min(1, "Le mot de passe est obligatoire."),
});

// ---- requests / expenses ---------------------------------------------------
const requestBody = {
  amount: fcfa,
  beneficiary_type: z.enum(["internal", "external"], { errorMap: () => ({ message: "Type de bénéficiaire invalide." }) }),
  purpose: nonEmpty("L'objet"),
  category: nonEmpty("La catégorie"),
  proposed_treasury: treasury,
  beneficiary_user_id: uuid.optional(),
  beneficiary_name: z.string().trim().min(1).optional(),
  project: z.string().trim().optional(),
  urgency: z.enum(["low", "normal", "high", "urgent"]).default("normal"),
  desired_date: optDate,
};
const beneficiaryRefine = (val: { beneficiary_type: string; beneficiary_user_id?: string; beneficiary_name?: string }, ctx: z.RefinementCtx) => {
  if (val.beneficiary_type === "internal" && !val.beneficiary_user_id)
    ctx.addIssue({ code: "custom", message: "Un bénéficiaire interne est requis.", path: ["beneficiary_user_id"] });
  if (val.beneficiary_type === "external" && !val.beneficiary_name)
    ctx.addIssue({ code: "custom", message: "Le nom du bénéficiaire externe est requis.", path: ["beneficiary_name"] });
};
export const createRequestSchema = z.object(requestBody).superRefine(beneficiaryRefine);
export const correctionSchema = z.object({ request_id: uuid, ...requestBody }).superRefine(beneficiaryRefine);

export const validationSchema = z.object({
  version_id: uuid,
  decision: z.enum(["approved", "not_approved", "correction_requested"], { errorMap: () => ({ message: "Décision invalide." }) }),
  comment: z.string().trim().optional(),
}).superRefine((v, ctx) => {
  if (v.decision !== "approved" && !v.comment)
    ctx.addIssue({ code: "custom", message: "Un commentaire est obligatoire pour un refus ou une demande de correction.", path: ["comment"] });
});

export const payRequestSchema = z.object({ request_id: uuid, idempotency_key: idem });
export const disburseAdvanceSchema = z.object({ request_id: uuid, idempotency_key: idem });
export const incomeSchema = z.object({ account_id: uuid, amount: fcfa, memo: z.string().trim().optional(), source_id: uuid.optional() });

// ---- controls & documents --------------------------------------------------
export const accountingControlSchema = z.object({
  payment_id: uuid,
  decision: z.enum(["validated", "not_validated"], { errorMap: () => ({ message: "Décision de contrôle invalide." }) }),
  cause: z.string().trim().optional(),
  comment: z.string().trim().optional(),
}).superRefine((v, ctx) => {
  if (v.decision === "not_validated" && !v.cause)
    ctx.addIssue({ code: "custom", message: "Une cause est obligatoire lorsque le contrôle n'est pas validé.", path: ["cause"] });
});

export const attachmentMetaSchema = z.object({
  entity_type: nonEmpty("Le type d'entité"),
  entity_id: uuid,
  file_name: nonEmpty("Le nom du fichier"),
  mime_type: nonEmpty("Le type de fichier"),
  byte_size: z.coerce.number().int().positive("Taille de fichier invalide."),
  storage_path: nonEmpty("Le chemin de stockage"),
  sha256: z.string().trim().min(16, "Empreinte du fichier invalide."),
});
export const internalReceiptSchema = z.object({
  payment_id: uuid,
  status: z.enum(["received", "not_received", "disputed"], { errorMap: () => ({ message: "Statut de réception invalide." }) }),
  comment: z.string().trim().optional(),
});

// ---- transfers -------------------------------------------------------------
export const transferInitiateSchema = z.object({
  direction: z.enum(["small_to_large", "large_to_small"], { errorMap: () => ({ message: "Sens du transfert invalide." }) }),
  amount: fcfa,
  idempotency_key: idem,
});
export const transferConfirmSchema = z.object({ transfer_id: uuid });
export const transferCancelSchema = z.object({ transfer_id: uuid, reason: nonEmpty("Le motif") });

// ---- salaries --------------------------------------------------------------
export const salaryProfileSchema = z.object({
  user_id: uuid,
  salary_eligible: z.boolean(),
  monthly_salary: fcfa0,
  can_request_advance: z.boolean(),
  advance_ceiling: fcfa0,
  effective_date: z.coerce.date(),
  note: z.string().trim().optional(),
}).superRefine((v, ctx) => {
  if (v.advance_ceiling > v.monthly_salary)
    ctx.addIssue({ code: "custom", message: "Le plafond d'avance ne peut pas dépasser le salaire mensuel.", path: ["advance_ceiling"] });
});
export const salaryAdvanceRequestSchema = z.object({ period: z.coerce.date(), amount: fcfa });
export const salaryAdvancePaySchema = z.object({ request_id: uuid, idempotency_key: idem });
export const salaryBalancePaySchema = z.object({ cycle_id: uuid, idempotency_key: idem });
export const openCycleSchema = z.object({ user_id: uuid, period: z.coerce.date() });

// ---- investments & capital -------------------------------------------------
export const investmentCreateSchema = z.object({
  amount: fcfa,
  supplier: nonEmpty("Le fournisseur"),
  asset_name: nonEmpty("Le nom du bien"),
  asset_category: nonEmpty("La catégorie du bien"),
  custodian_user_id: uuid.optional(),
  custodian_name: z.string().trim().optional(),
  project: z.string().trim().optional(),
});
export const investmentPaySchema = z.object({ request_id: uuid, idempotency_key: idem, acquired_on: optDate });
export const capitalDeclareSchema = z.object({ amount: fcfa });
export const capitalConfirmSchema = z.object({
  contribution_id: uuid,
  confirmed: z.boolean(),
  idempotency_key: idem,
  cause: z.string().trim().optional(),
}).superRefine((v, ctx) => {
  if (!v.confirmed && !v.cause)
    ctx.addIssue({ code: "custom", message: "Une cause est obligatoire lorsque la réception n'est pas confirmée.", path: ["cause"] });
});

// ---- loans & borrowings ----------------------------------------------------
export const loanRequestSchema = z.object({ amount: fcfa, borrower_name: nonEmpty("L'emprunteur"), purpose: z.string().trim().optional(), project: z.string().trim().optional() });
export const loanDisburseSchema = z.object({ request_id: uuid, idempotency_key: idem });
export const loanInstallmentSchema = z.object({ loan_id: uuid, amount: fcfa, due_date: optDate });
export const loanRepaymentSchema = z.object({ installment_id: uuid, idempotency_key: idem });

export const borrowingEnterSchema = z.object({ lender_name: nonEmpty("Le prêteur"), principal: fcfa });
export const borrowingConfirmSchema = z.object({
  borrowing_id: uuid, confirmed: z.boolean(), idempotency_key: idem, cause: z.string().trim().optional(),
}).superRefine((v, ctx) => {
  if (!v.confirmed && !v.cause)
    ctx.addIssue({ code: "custom", message: "Une cause est obligatoire lorsque la réception n'est pas confirmée.", path: ["cause"] });
});
export const borrowingRepaymentRequestSchema = z.object({
  borrowing_id: uuid, principal_part: fcfa0, interest_part: fcfa0.default(0), charges_part: fcfa0.default(0),
}).superRefine((v, ctx) => {
  if ((v.principal_part + v.interest_part + v.charges_part) <= 0)
    ctx.addIssue({ code: "custom", message: "Une échéance de remboursement doit être positive.", path: ["principal_part"] });
});
export const borrowingRepaymentPaySchema = z.object({ request_id: uuid, idempotency_key: idem });

// ---- reports / history -----------------------------------------------------
export const exportSchema = z.object({ report_type: nonEmpty("Le type de rapport"), filters: z.record(z.unknown()).default({}) });
export const historyFilterSchema = z.object({
  date_from: optDate,
  date_to: optDate,
  treasury: z.enum(["SMALL", "LARGE", "TRANSIT"]).optional(),
  movement_type: z.string().optional(),
  amount_min: z.coerce.number().int().optional(),
  amount_max: z.coerce.number().int().optional(),
  reference: z.string().trim().optional(),
  source_type: z.string().trim().optional(),
  posted_by: z.string().trim().optional(),
  limit: z.coerce.number().int().positive().max(500).default(100),
  offset: z.coerce.number().int().nonnegative().default(0),
});

// ---- inferred input types --------------------------------------------------
export type LoginInput = z.infer<typeof loginSchema>;
export type CreateRequestInput = z.infer<typeof createRequestSchema>;
export type CorrectionInput = z.infer<typeof correctionSchema>;
export type ValidationInput = z.infer<typeof validationSchema>;
export type AccountingControlInput = z.infer<typeof accountingControlSchema>;
export type AttachmentMetaInput = z.infer<typeof attachmentMetaSchema>;
export type TransferInitiateInput = z.infer<typeof transferInitiateSchema>;
export type SalaryProfileInput = z.infer<typeof salaryProfileSchema>;
export type InvestmentCreateInput = z.infer<typeof investmentCreateSchema>;
export type HistoryFilter = z.infer<typeof historyFilterSchema>;
