import "server-only";
import postgres from "postgres";

/**
 * Single PostgreSQL client for the whole app. Every request runs inside a
 * transaction that sets the database ROLE and the acting user identity, so that
 * Row-Level Security and the SECURITY DEFINER functions are enforced by the
 * database itself — the service layer can only call functions and read views,
 * never write the ledger directly.
 *
 *   withUser(userId, tx => …)  -> SET LOCAL ROLE app_user + app.current_user_id
 *   withService(tx => …)       -> SET LOCAL ROLE service_role (auth/bootstrap)
 *
 * The connecting role must be a member of app_user and service_role (or a
 * superuser in dev). Never connect the app as a superuser in production.
 */

const numericAsNumber = {
  // FCFA amounts are integers (numeric(18,0)); return them as JS numbers.
  to: 1700,
  from: [1700],
  serialize: (x: number) => x.toString(),
  parse: (x: string) => Number(x),
};

const options: postgres.Options<Record<string, postgres.PostgresType>> = {
  max: Number(process.env.PG_POOL_MAX ?? 10),
  idle_timeout: 20,
  onnotice: () => {},
  types: { numeric: numericAsNumber },
};

function makeClient() {
  const url = process.env.DATABASE_URL;
  if (url) return postgres(url, options);
  return postgres({
    host: process.env.PGHOST ?? "/tmp",
    port: Number(process.env.PGPORT ?? 5432),
    database: process.env.PGDATABASE ?? "sepf",
    username: process.env.PGUSER ?? "postgres",
    password: process.env.PGPASSWORD,
    ...options,
  });
}

// Reuse a single client across hot-reloads in dev.
const g = globalThis as unknown as { __sepfSql?: postgres.Sql };
export const sql: postgres.Sql = g.__sepfSql ?? makeClient();
if (process.env.NODE_ENV !== "production") g.__sepfSql = sql;

export type Tx = postgres.TransactionSql<Record<string, postgres.PostgresType>>;

/** Run `fn` as app_user, acting as `userId` (RLS + SECURITY DEFINER enforced). */
export async function withUser<T>(userId: string, fn: (tx: Tx) => Promise<T>): Promise<T> {
  return sql.begin(async (tx) => {
    await tx`set local role app_user`;
    await tx`select set_config('app.current_user_id', ${userId}, true)`;
    return fn(tx as Tx);
  }) as Promise<T>;
}

/** Run `fn` as service_role (trusted path: authentication, session, bootstrap). */
export async function withService<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
  return sql.begin(async (tx) => {
    await tx`set local role service_role`;
    return fn(tx as Tx);
  }) as Promise<T>;
}
