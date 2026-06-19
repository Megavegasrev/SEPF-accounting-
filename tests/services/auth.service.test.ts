import { describe, it, expect } from "vitest";
import * as auth from "@/services/auth.service";
import { EMAILS, USERS, PASSWORD } from "../setup/testdb";

describe("auth.service", () => {
  it("logs in with correct credentials and returns role + permissions", async () => {
    const res = await auth.login({ email: EMAILS.cashier, password: PASSWORD });
    expect(res.token).toBeTruthy();
    expect(res.user.role).toBe("cashier");
    expect(res.user.permissions).toContain("income.record.small");
    expect(res.user.permissions).not.toContain("request.approve.final");
  });

  it("rejects a wrong password with a French message", async () => {
    await expect(auth.login({ email: EMAILS.cashier, password: "wrong" }))
      .rejects.toMatchObject({ message: "Identifiants invalides.", httpStatus: 401 });
  });

  it("resolves and then revokes a session token", async () => {
    const { token } = await auth.login({ email: EMAILS.super, password: PASSWORD });
    expect(await auth.getSessionUserId(token)).toBe(USERS.super);
    await auth.logout(token);
    expect(await auth.getSessionUserId(token)).toBeNull();
  });

  it("loads the current user with the expected permission set", async () => {
    const me = await auth.getCurrentUser(USERS.super);
    expect(me.role).toBe("super_admin");
    expect(me.permissions).toContain("request.approve.final");
    const acct = await auth.getCurrentUser(USERS.accountant);
    expect(acct.permissions).toContain("salary.pay");
    expect(acct.permissions).toContain("accounting.control");
  });
});
