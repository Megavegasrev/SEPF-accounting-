import { describe, it, expect } from "vitest";
import * as auth from "@/services/auth.service";
import { homePathForRole } from "@/lib/auth/redirect";
import { EMAILS, USERS, PASSWORD } from "../setup/testdb";

describe("authentication flow (login -> session -> redirect -> logout)", () => {
  it("logs in each of the five roles and resolves the role-based redirect", async () => {
    for (const key of Object.keys(EMAILS) as (keyof typeof EMAILS)[]) {
      const res = await auth.login({ email: EMAILS[key], password: PASSWORD });
      expect(res.token).toBeTruthy();
      expect(res.user.role).toBeTruthy();
      expect(homePathForRole(res.user.role)).toBe("/");
    }
  });

  it("treats missing/invalid session tokens as unauthenticated (protected-route basis)", async () => {
    expect(await auth.getSessionUserId(undefined)).toBeNull();
    expect(await auth.getSessionUserId("not-a-real-token")).toBeNull();
  });

  it("logs out: the session token stops resolving afterwards", async () => {
    const { token } = await auth.login({ email: EMAILS.accountant, password: PASSWORD });
    expect(await auth.getSessionUserId(token)).toBe(USERS.accountant);
    await auth.logout(token);
    expect(await auth.getSessionUserId(token)).toBeNull();
  });
});
