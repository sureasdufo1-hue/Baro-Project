import { defineConfig, devices } from "@playwright/test";

// Set E2E_EXTERNAL_SERVER=1 to run against an already-running web server
// (e.g. the docker compose stack, which serves the web app on port 3004).
const externalServer = Boolean(process.env.E2E_EXTERNAL_SERVER);
const baseURL = process.env.E2E_BASE_URL ?? "http://localhost:3004";

export default defineConfig({
  testDir: "tests/e2e",
  timeout: 30_000,
  retries: 1,
  use: {
    baseURL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: externalServer
    ? undefined
    : {
        command: "pnpm --filter @claimlens/web exec next dev --port 3004",
        url: `${baseURL}/login`,
        reuseExistingServer: true,
        timeout: 120_000,
      },
});
