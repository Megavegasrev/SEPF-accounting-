import "server-only";
import { randomBytes, createHash } from "node:crypto";
import { withService, type Tx } from "@/db/client";
import type { UUID } from "@/lib/types";

/** Opaque session token handed to the client; only its SHA-256 hash is stored. */
export function generateToken(): string {
  return randomBytes(32).toString("base64url");
}
export function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

function ttlMinutes(): number {
  return Number(process.env.SESSION_TTL_MINUTES ?? 60);
}

/** Create a session row (trusted path) and return the raw token. */
export async function createSession(
  userId: UUID,
  meta: { ip?: string; userAgent?: string } = {},
): Promise<{ token: string; expiresAt: Date }> {
  const token = generateToken();
  const tokenHash = hashToken(token);
  const expiresAt = new Date(Date.now() + ttlMinutes() * 60_000);
  await withService(async (tx: Tx) => {
    await tx`
      insert into sessions (user_id, token_hash, expires_at, ip, user_agent)
      values (${userId}, ${tokenHash}, ${expiresAt}, ${meta.ip ?? null}, ${meta.userAgent ?? null})
    `;
  });
  return { token, expiresAt };
}

/** Resolve a raw token to an active user id, or null. */
export async function lookupSession(token: string): Promise<UUID | null> {
  if (!token) return null;
  const tokenHash = hashToken(token);
  return withService(async (tx: Tx) => {
    const rows = await tx<{ user_id: UUID }[]>`
      select s.user_id
      from sessions s
      join users u on u.id = s.user_id
      where s.token_hash = ${tokenHash}
        and s.revoked_at is null
        and s.expires_at > now()
        and u.status = 'active'
      limit 1
    `;
    return rows[0]?.user_id ?? null;
  });
}

/** Revoke a session (logout). Safe to call with an unknown token. */
export async function revokeSession(token: string): Promise<void> {
  if (!token) return;
  const tokenHash = hashToken(token);
  await withService(async (tx: Tx) => {
    await tx`update sessions set revoked_at = now() where token_hash = ${tokenHash} and revoked_at is null`;
  });
}
