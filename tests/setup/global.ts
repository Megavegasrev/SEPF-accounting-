import { execFileSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import bcrypt from "bcryptjs";

/**
 * Vitest globalSetup: build a throwaway `sepf_test` database from the SAME
 * migrations + seeds the project ships, then set a known password on the five
 * demo accounts so the auth tests can sign in. Runs once per test run.
 */
const PG = ["-h", process.env.PGHOST ?? "/tmp", "-p", process.env.PGPORT ?? "55432", "-U", process.env.PGUSER ?? "postgres"];
const DB = "sepf_test";

function run(args: string[], db?: string) {
  execFileSync("psql", [...PG, ...(db ? ["-d", db] : []), ...args], { stdio: "pipe" });
}

export default function setup() {
  run(["-v", "ON_ERROR_STOP=1", "-q", "-c", `drop database if exists ${DB};`, "-c", `create database ${DB};`]);
  const root = process.cwd();
  for (const dir of ["db/migrations", "db/seed"]) {
    const files = readdirSync(join(root, dir)).filter((f) => f.endsWith(".sql")).sort();
    for (const f of files) run(["-v", "ON_ERROR_STOP=1", "-q", "-f", join(root, dir, f)], DB);
  }
  const hash = bcrypt.hashSync("Test1234!", 10);
  run(["-q", "-c", `update users set password_hash = '${hash}', must_change_password = false where email like '%@sepf.test';`], DB);
}
