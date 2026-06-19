/**
 * Permission codes (mirror db/seed/*). Used by the UI to show/hide actions
 * (e.g. the floating "+" button). The DATABASE remains authoritative: every
 * function re-checks the permission, so a UI mistake can never grant access.
 */
export const PERMISSIONS = {
  // rbac / users
  rbacManage: "rbac.manage",
  usersRead: "users.read",
  usersManage: "users.manage",
  // ledger
  ledgerReadFull: "ledger.read.full",
  ledgerReadSmall: "ledger.read.small",
  incomeRecordSmall: "income.record.small",
  incomeRecordLarge: "income.record.large",
  movementReverse: "movement.reverse",
  treasuryConfigure: "treasury.configure",
  settingsManage: "settings.manage",
  auditRead: "audit.read",
  // requests
  requestCreate: "request.create",
  requestReadAll: "request.read.all",
  requestApproveFirst: "request.approve.first",
  requestApproveFinal: "request.approve.final",
  expensePaySmall: "expense.pay.small",
  expensePayLarge: "expense.pay.large",
  expenseDisburseAdvance: "expense.disburse_advance",
  // controls & transfers
  accountingControl: "accounting.control",
  attachmentAdd: "attachment.add",
  receiptConfirm: "receipt.confirm",
  transferRead: "transfer.read",
  transferInitiateSmallToLarge: "transfer.initiate.small_to_large",
  transferInitiateLargeToSmall: "transfer.initiate.large_to_small",
  transferConfirmSmallToLarge: "transfer.confirm.small_to_large",
  transferConfirmLargeToSmall: "transfer.confirm.large_to_small",
  transferCancel: "transfer.cancel",
  // salaries
  salaryConfigure: "salary.configure",
  salaryRead: "salary.read",
  salaryPay: "salary.pay",
  // investments & capital
  investmentCreate: "investment.create",
  investmentPay: "investment.pay",
  investmentRead: "investment.read",
  capitalContribute: "capital.contribute",
  capitalConfirm: "capital.confirm",
  capitalRead: "capital.read",
  // loans / borrowings / reports
  loanDisburse: "loan.disburse",
  loanManage: "loan.manage",
  loanRead: "loan.read",
  borrowingEnter: "borrowing.enter",
  borrowingConfirm: "borrowing.confirm",
  borrowingRepay: "borrowing.repay",
  borrowingRead: "borrowing.read",
  reportExport: "report.export",
} as const;

export type PermissionCode = (typeof PERMISSIONS)[keyof typeof PERMISSIONS];

export function can(perms: readonly string[], code: PermissionCode): boolean {
  return perms.includes(code);
}
