/** Fixed demo-user ids (from db/seed/0002) and the test password. */
export const USERS = {
  super: "11111111-1111-1111-1111-111111111111",
  validator: "22222222-2222-2222-2222-222222222222",
  ops: "33333333-3333-3333-3333-333333333333",
  cashier: "44444444-4444-4444-4444-444444444444",
  accountant: "55555555-5555-5555-5555-555555555555",
} as const;

export const EMAILS = {
  super: "superadmin@sepf.test",
  validator: "validator@sepf.test",
  ops: "operations@sepf.test",
  cashier: "cashier@sepf.test",
  accountant: "accountant@sepf.test",
} as const;

export const PASSWORD = "Test1234!";
