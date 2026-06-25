import "server-only";
import { runUser, one } from "@/services/_run";
import type { User, Setting, TreasuryAccount, UUID } from "@/lib/types";

/**
 * Administrative operations. Each call runs as the acting user (app_user); the
 * SECURITY DEFINER functions enforce the required permission (users.manage,
 * settings.manage, rbac.manage, treasury.configure) and write the audit log.
 * There are no direct write policies on users/roles/permissions/settings —
 * these functions are the only way in.
 */

export async function createUser(
  actor: UUID,
  input: { email: string; full_name: string; role_code: string; password_hash?: string | null },
): Promise<User> {
  return runUser(actor, async (tx) => one(await tx<User[]>`
    select * from admin_create_user(${input.email}, ${input.full_name}, ${input.role_code}, ${input.password_hash ?? null})
  `));
}

export async function setUserStatus(actor: UUID, userId: UUID, status: "active" | "suspended"): Promise<User> {
  return runUser(actor, async (tx) => one(await tx<User[]>`
    select * from admin_set_user_status(${userId}, ${status})
  `));
}

export async function setUserRole(actor: UUID, userId: UUID, roleCode: string): Promise<User> {
  return runUser(actor, async (tx) => one(await tx<User[]>`
    select * from admin_set_user_role(${userId}, ${roleCode})
  `));
}

export async function setSetting(actor: UUID, key: string, value: unknown, description?: string): Promise<Setting> {
  return runUser(actor, async (tx) => one(await tx<Setting[]>`
    select * from admin_set_setting(${key}, ${JSON.stringify(value)}::jsonb, ${description ?? null})
  `));
}

export async function setRolePermission(actor: UUID, roleCode: string, permissionCode: string, grant: boolean): Promise<void> {
  await runUser(actor, (tx) => tx`select admin_set_role_permission(${roleCode}, ${permissionCode}, ${grant})`);
}

export async function updateTreasuryAccount(
  actor: UUID,
  accountId: UUID,
  input: { name?: string | null; responsible_user_id?: UUID | null; is_active?: boolean | null },
): Promise<TreasuryAccount> {
  return runUser(actor, async (tx) => one(await tx<TreasuryAccount[]>`
    select * from admin_update_treasury_account(
      ${accountId}, ${input.name ?? null}, ${input.responsible_user_id ?? null}, ${input.is_active ?? null})
  `));
}

/** Revoke every active session of a user (used by suspend; needs users.manage). */
export async function revokeUserSessions(actor: UUID, userId: UUID): Promise<number> {
  return runUser(actor, async (tx) => {
    const rows = await tx<{ revoke_user_sessions: number }[]>`select revoke_user_sessions(${userId})`;
    return rows[0]?.revoke_user_sessions ?? 0;
  });
}
