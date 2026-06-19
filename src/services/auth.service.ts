import "server-only";
import { runService, runUser } from "@/services/_run";
import { withService, withUser } from "@/db/client";
import { AppError } from "@/db/errors";
import { verifyPassword, hashPassword } from "@/lib/password";
import { createSession, lookupSession, revokeSession } from "@/lib/session";
import { loginSchema, type LoginInput } from "@/lib/schemas";
import type { CurrentUser, UUID, User } from "@/lib/types";

/** Authenticate and open a session. Never reveals which factor failed. */
export async function login(
  input: LoginInput,
  meta: { ip?: string; userAgent?: string } = {},
): Promise<{ token: string; expiresAt: Date; user: CurrentUser }> {
  const { email, password } = loginSchema.parse(input);

  const user = await runService(async (tx) => {
    const rows = await tx<User[]>`
      select * from users where email = ${email} and status = 'active' limit 1
    `;
    return rows[0] ?? null;
  });

  const ok = user ? await verifyPassword(password, user.password_hash) : false;

  await runService(async (tx) => {
    await tx`
      insert into login_events (user_id, email_attempted, event, ip, user_agent)
      values (${user?.id ?? null}, ${email}, ${ok ? "login_success" : "login_failure"},
              ${meta.ip ?? null}, ${meta.userAgent ?? null})
    `;
  });

  if (!user || !ok) {
    throw new AppError("Identifiants invalides.", "auth_failed", 401);
  }

  const { token, expiresAt } = await createSession(user.id, meta);
  await runService(async (tx) => {
    await tx`update users set last_login_at = now() where id = ${user.id}`;
  });
  const current = await getCurrentUser(user.id);
  return { token, expiresAt, user: current };
}

export async function logout(token: string): Promise<void> {
  await revokeSession(token);
}

/** Resolve a raw session token to the acting user id (or null). */
export async function getSessionUserId(token: string | undefined | null): Promise<UUID | null> {
  if (!token) return null;
  return lookupSession(token);
}

/** Load the current user's profile + role + permission codes (RLS-scoped). */
export async function getCurrentUser(userId: UUID): Promise<CurrentUser> {
  return runUser(userId, async (tx) => {
    const [profile] = await tx<{ id: UUID; email: string; full_name: string; role: string; role_name: string }[]>`
      select u.id, u.email, u.full_name, r.code as role, r.name as role_name
      from users u join roles r on r.id = u.role_id
      where u.id = app_current_user_id()
    `;
    if (!profile) throw new AppError("Utilisateur introuvable.", "not_found", 404);
    const perms = await tx<{ code: string }[]>`
      select p.code
      from permissions p
      join role_permissions rp on rp.permission_id = p.id
      join users u on u.role_id = rp.role_id
      where u.id = app_current_user_id()
      order by p.code
    `;
    return {
      id: profile.id,
      email: profile.email,
      full_name: profile.full_name,
      role: profile.role as CurrentUser["role"],
      role_name: profile.role_name,
      permissions: perms.map((p) => p.code),
    };
  });
}

/**
 * Bootstrap helper (Phase 6 / deploy): set a user's password on the trusted
 * path. Not exposed to the UI; there is no public registration.
 */
export async function setUserPassword(userId: UUID, plain: string): Promise<void> {
  const hash = await hashPassword(plain);
  await runService(async (tx) => {
    await tx`update users set password_hash = ${hash}, must_change_password = false where id = ${userId}`;
  });
}

// re-export for callers that compose their own transactions
export { withService, withUser };
