/**
 * TypeScript types mirroring the SEPF database tables, views and function
 * returns. Field names are snake_case to match the columns exactly (no mapping
 * layer = no drift). Money is numeric(18,0) in FCFA, returned as a JS integer.
 * Timestamps/dates come back as JS Date (postgres.js).
 */

// ---- enums / unions (mirror the DB CHECK constraints) ----------------------
export type RoleCode =
  | "super_admin" | "first_validator" | "operations_director" | "cashier" | "accountant";

export type AccountType = "small_treasury" | "large_treasury" | "funds_in_transit";

export type MovementType =
  | "income" | "expense" | "transfer_out" | "transfer_in" | "salary" | "salary_advance"
  | "investment" | "loan_disbursement" | "loan_repayment" | "borrowing_receipt"
  | "borrowing_repayment" | "capital_contribution" | "adjustment" | "reversal";

export type RequestType = "expense" | "salary_advance" | "investment" | "loan" | "borrowing_repayment";
export type RequestVersionStatus =
  | "pending_first" | "pending_final" | "approved" | "rejected" | "correction_requested" | "superseded";
export type ValidationLevel = "first" | "final";
export type ValidationDecision = "approved" | "not_approved" | "correction_requested";
export type BeneficiaryType = "internal" | "external";
export type PaymentStatus = "completed" | "disbursed_pending" | "disbursed_unapproved";
export type ControlDecision = "validated" | "not_validated";
export type ReceiptStatus = "received" | "not_received" | "disputed";
export type TransferDirection = "small_to_large" | "large_to_small";
export type TransferStatus = "pending" | "confirmed" | "cancelled";
export type CapitalStatus = "awaiting_receipt" | "confirmed" | "not_confirmed";
export type BorrowingStatus = "awaiting_receipt" | "received" | "not_received";
export type LoanStatus = "pending" | "disbursed";
export type LoanRepaymentStatus = "scheduled" | "received";
export type InstallmentStatus = "pending" | "paid";

export type UUID = string;

// ---- users & security ------------------------------------------------------
export interface Role { id: UUID; code: RoleCode; name: string; description: string | null; created_at: Date; }
export interface Permission { id: UUID; code: string; domain: string; description: string; created_at: Date; }
export interface User {
  id: UUID; email: string; full_name: string; role_id: UUID;
  status: "active" | "suspended"; password_hash: string | null; auth_user_id: UUID | null;
  must_change_password: boolean; last_login_at: Date | null; created_by: UUID | null;
  created_at: Date; updated_at: Date;
}
export interface Session {
  id: UUID; user_id: UUID; token_hash: string; issued_at: Date; expires_at: Date;
  revoked_at: Date | null; ip: string | null; user_agent: string | null;
}
/** Shape sent to the UI after login / on every protected request. */
export interface CurrentUser {
  id: UUID; email: string; full_name: string; role: RoleCode; role_name: string;
  permissions: string[];
}

// ---- treasury & ledger -----------------------------------------------------
export interface TreasuryBalance {
  account_id: UUID; account_type: AccountType; code: string; name: string;
  currency: string; balance: number; movement_count: number; last_movement_at: Date | null;
}
export interface TreasuryConsolidated {
  small_treasury: number; large_treasury: number; funds_in_transit: number; total_treasury: number;
}
export interface IncomeEntry {
  id: UUID; movement_id: UUID; account_id: UUID; amount: number; source_payer: string | null;
  income_type: string | null; purpose: string | null; operation_date: Date; payment_method: string | null;
  external_reference: string | null; project: string | null; recorded_by: UUID; idempotency_key: string; created_at: Date;
}
export interface TreasuryMovement {
  id: UUID; account_id: UUID; amount: number; movement_type: MovementType; reference: string;
  idempotency_key: string; movement_group_id: UUID | null; source_type: string | null;
  source_id: UUID | null; reverses_movement_id: UUID | null; memo: string | null;
  posted_at: Date; posted_by: UUID; created_at: Date;
}

// ---- requests, approvals & payments ----------------------------------------
export interface RequestRow { id: UUID; reference: string; request_type: RequestType; requester_id: UUID; created_at: Date; }
export interface RequestVersion {
  id: UUID; request_id: UUID; version_number: number; amount: number; beneficiary_type: BeneficiaryType;
  beneficiary_user_id: UUID | null; beneficiary_name: string | null; purpose: string; category: string;
  proposed_treasury: "small_treasury" | "large_treasury"; project: string | null; urgency: string;
  desired_date: Date | null; status: RequestVersionStatus; created_by: UUID; created_at: Date;
}
export interface RequestValidation {
  id: UUID; request_version_id: UUID; level: ValidationLevel; decision: ValidationDecision;
  comment: string | null; is_self_decision: boolean; decided_by: UUID; decided_at: Date;
}
export interface Payment {
  id: UUID; request_id: UUID; request_version_id: UUID; treasury_account_id: UUID; amount: number;
  movement_id: UUID; is_advance: boolean; status: PaymentStatus; paid_by: UUID; paid_at: Date;
}
export interface RequestOverview {
  request_id: UUID; reference: string; requester_id: UUID; created_at: Date; latest_version_id: UUID;
  latest_version: number; amount: number; proposed_treasury: string; beneficiary_type: BeneficiaryType;
  status: RequestVersionStatus;
}

// ---- controls & documents --------------------------------------------------
export interface AccountingControl {
  id: UUID; payment_id: UUID; decision: ControlDecision; cause: string | null; comment: string | null;
  controlled_by: UUID; controlled_at: Date;
}
export interface Attachment {
  id: UUID; entity_type: string; entity_id: UUID; file_name: string; mime_type: string; byte_size: number;
  storage_path: string; sha256: string; is_potential_duplicate: boolean; duplicate_of_id: UUID | null;
  is_active: boolean; replaced_by_id: UUID | null; uploaded_by: UUID; uploaded_at: Date;
}
export interface InternalReceipt {
  id: UUID; payment_id: UUID; beneficiary_user_id: UUID; status: ReceiptStatus; comment: string | null; recorded_at: Date;
}
export interface PaymentControlStatus {
  payment_id: UUID; request_id: UUID; payment_status: PaymentStatus;
  control_decision: ControlDecision | null; controlled_at: Date | null; controlled_by: UUID | null;
}

// ---- transfers -------------------------------------------------------------
export interface InternalTransfer {
  id: UUID; reference: string; idempotency_key: string; direction: TransferDirection; amount: number;
  status: TransferStatus; source_account_id: UUID; destination_account_id: UUID; transit_account_id: UUID;
  initiated_by: UUID; initiated_at: Date; confirmed_by: UUID | null; confirmed_at: Date | null;
  cancelled_by: UUID | null; cancelled_at: Date | null; cancel_reason: string | null;
}

// ---- salaries --------------------------------------------------------------
export interface SalaryProfile {
  id: UUID; user_id: UUID; salary_eligible: boolean; monthly_salary: number; can_request_advance: boolean;
  monthly_advance_ceiling: number; effective_date: Date; is_active: boolean; note: string | null;
  created_by: UUID; created_at: Date;
}
export interface SalaryCycle {
  id: UUID; user_id: UUID; period: Date; monthly_salary: number; advance_ceiling: number;
  can_request_advance: boolean; created_at: Date;
}
export interface SalaryAdvanceRequest { id: UUID; request_id: UUID; cycle_id: UUID; user_id: UUID; amount: number; created_at: Date; }
export interface SalaryBalancePayment { id: UUID; cycle_id: UUID; amount: number; movement_id: UUID; idempotency_key: string; paid_by: UUID; paid_at: Date; }
export interface SalaryCycleSummary {
  cycle_id: UUID; user_id: UUID; period: Date; monthly_salary: number; advance_ceiling: number;
  advances_paid: number; advances_approved_unpaid: number; advance_available: number;
  balance_paid: number; outstanding_balance: number;
}

// ---- investments & capital -------------------------------------------------
export interface Investment {
  id: UUID; request_id: UUID; supplier: string; asset_name: string; asset_category: string;
  custodian_user_id: UUID | null; custodian_name: string | null; created_by: UUID; created_at: Date;
}
export interface Asset {
  id: UUID; investment_id: UUID; cost: number; acquired_on: Date; custodian_user_id: UUID | null;
  custodian_name: string | null; payment_id: UUID; movement_id: UUID; created_by: UUID; created_at: Date;
}
export interface AssetRegister {
  asset_id: UUID; asset_name: string; asset_category: string; supplier: string; cost: number;
  acquired_on: Date; custodian: string | null; payment_id: UUID; request_id: UUID;
}
export interface CapitalContribution {
  id: UUID; reference: string; shareholder_user_id: UUID; amount: number; status: CapitalStatus;
  declared_by: UUID; declared_at: Date; confirmed_by: UUID | null; confirmed_at: Date | null;
  not_confirmed_cause: string | null; movement_id: UUID | null; confirm_idempotency_key: string | null;
}
export interface ShareholderCapitalSummary {
  shareholder_user_id: UUID; contributions: number; total_awaiting: number; total_confirmed: number; total_not_confirmed: number;
}

// ---- loans & borrowings ----------------------------------------------------
export interface LoanGranted {
  id: UUID; request_id: UUID; borrower_name: string; principal: number; status: LoanStatus;
  disbursement_movement_id: UUID | null; disbursed_by: UUID | null; disbursed_at: Date | null;
  created_by: UUID; created_at: Date;
}
export interface LoanRepayment {
  id: UUID; loan_id: UUID; amount: number; due_date: Date | null; status: LoanRepaymentStatus;
  movement_id: UUID | null; idempotency_key: string | null; received_by: UUID | null; received_at: Date | null; created_at: Date;
}
export interface LoanSummary { loan_id: UUID; request_id: UUID; borrower_name: string; principal: number; status: LoanStatus; repaid: number; outstanding_receivable: number; }
export interface CompanyBorrowing {
  id: UUID; reference: string; lender_name: string; principal: number; status: BorrowingStatus;
  entered_by: UUID; entered_at: Date; confirmed_by: UUID | null; confirmed_at: Date | null;
  not_received_cause: string | null; receipt_movement_id: UUID | null; confirm_idempotency_key: string | null;
}
export interface BorrowingInstallment {
  id: UUID; borrowing_id: UUID; request_id: UUID; principal_part: number; interest_part: number;
  charges_part: number; status: InstallmentStatus; payment_movement_id: UUID | null; paid_by: UUID | null;
  paid_at: Date | null; created_at: Date; installment_number: number | null; due_date: Date | null;
}
export interface BorrowingSummary {
  borrowing_id: UUID; reference: string; lender_name: string; principal: number; status: BorrowingStatus;
  principal_repaid: number; interest_paid: number; charges_paid: number; outstanding_liability: number;
}

// ---- history & audit -------------------------------------------------------
export interface TransactionHistoryRow {
  movement_id: UUID; posted_at: Date; treasury: string; account_type: AccountType; movement_type: MovementType;
  amount: number; reference: string; memo: string | null; source_type: string | null; source_id: UUID | null;
  movement_group_id: UUID | null; posted_by: string | null;
}
export interface AuditLog {
  id: UUID; actor_user_id: UUID | null; action: string; entity_type: string; entity_id: UUID | null;
  before: unknown; after: unknown; ip: string | null; request_id: string | null; created_at: Date;
}
