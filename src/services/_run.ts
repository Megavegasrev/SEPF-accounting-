import "server-only";
import { randomUUID } from "node:crypto";
import { withUser, withService, type Tx } from "@/db/client";
import { toAppError } from "@/db/errors";

/** Run as the acting user (app_user + RLS), translating DB errors to French. */
export async function runUser<T>(actor: string, fn: (tx: Tx) => Promise<T>): Promise<T> {
  try {
    return await withUser(actor, fn);
  } catch (e) {
    throw toAppError(e);
  }
}

/** Run on the trusted path (service_role), translating DB errors to French. */
export async function runService<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
  try {
    return await withService(fn);
  } catch (e) {
    throw toAppError(e);
  }
}

export const newKey = (): string => randomUUID();
export const one = <T>(rows: T[]): T => {
  const r = rows[0];
  if (r === undefined) throw new Error("Aucun résultat renvoyé par la base de données.");
  return r;
};
