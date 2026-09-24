import { defineConfig } from "vitest/config";

// createDatabase applies ~2500 lines of triggers (~3.5 s); the 5 s default is too tight
// once test files run in parallel.
export default defineConfig({
  test: { testTimeout: 60000, fileParallelism: false, globalSetup: ["./test/globalSetup.ts"] },
});
