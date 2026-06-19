import { defineConfig } from "vitest/config";
import { fileURLToPath } from "node:url";

export default defineConfig({
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url)),
      // `server-only` throws when imported outside a Next server bundle; stub it.
      "server-only": fileURLToPath(new URL("./tests/setup/server-only-stub.ts", import.meta.url)),
    },
  },
  test: {
    environment: "node",
    include: ["tests/**/*.test.ts"],
    globalSetup: ["./tests/setup/global.ts"],
    // Service tests share one throwaway database; run files serially to keep
    // ledger assertions deterministic.
    fileParallelism: false,
    sequence: { concurrent: false },
    testTimeout: 30000,
    env: {
      PGHOST: process.env.PGHOST ?? "/tmp",
      PGPORT: process.env.PGPORT ?? "55432",
      PGUSER: process.env.PGUSER ?? "postgres",
      PGDATABASE: "sepf_test",
    },
  },
});
