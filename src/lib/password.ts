import "server-only";
import bcrypt from "bcryptjs";

const ROUNDS = 10;
/** A bcrypt hash that no password can match (locked account; mirrors the seed "!"). */
export const LOCKED_HASH = "!";

export async function hashPassword(plain: string): Promise<string> {
  return bcrypt.hash(plain, ROUNDS);
}

export async function verifyPassword(plain: string, hash: string | null): Promise<boolean> {
  if (!hash || hash === LOCKED_HASH || !hash.startsWith("$2")) return false;
  return bcrypt.compare(plain, hash);
}
