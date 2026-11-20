// SPDX-License-Identifier: Apache-2.0
//
// The browser test of the operator page (Fieldkit Processors), against a
// running runner that start.py builds: real API, real certificates, real
// reports. Run from this directory:
//   npm ci && npx playwright install chromium
//   RUNNER_BIN=../../target/debug/goat-processors npx playwright test
//
// Two ways in, as on a site:
//   operator: the mesh listener (mutual TLS), signed in with the client
//             certificate `ops`, which api.mesh.allow gives the operate role;
//   reader:   the local listener on 127.0.0.1, with no token: read only.

import { defineConfig, devices } from "@playwright/test";
import path from "node:path";

const base = Number(process.env.FIELDKIT_PORT) || 18470;
const API = base, MESH = base + 1, UDP = base + 2;
const RUN = path.resolve(".run");
const BIN = path.resolve(process.env.RUNNER_BIN || "../../target/debug/goat-processors");

export default defineConfig({
  testDir: ".",
  
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: "list",
  outputDir: "test-results",
  use: { trace: "retain-on-failure", ...devices["Desktop Chrome"] },
  projects: [
    {
      name: "operator",
      testMatch: /operator\.spec\.mjs/,
      use: {
        baseURL: `https://127.0.0.1:${MESH}`,
        // 127.0.0.1, not localhost: Playwright's certificate relay tries ::1 first
        // for localhost and waits there, and the test listener is IPv4 only.
        ignoreHTTPSErrors: true, // the test CA is not in the browser's store
        clientCertificates: [{ origin: `https://127.0.0.1:${MESH}`, certPath: `${RUN}/ops.pem`, keyPath: `${RUN}/ops.key` }],
      },
    },
    { name: "reader", testMatch: /reader\.spec\.mjs/, use: { baseURL: `http://127.0.0.1:${API}` }, dependencies: ["operator"] },
  ],
  webServer: {
    command: `python3 -I start.py --bin ${BIN} --packs ../../../packs --dir ${RUN} --api ${API} --mesh ${MESH} --udp ${UDP}`,
    url: `http://127.0.0.1:${API}/v1/health`,
    reuseExistingServer: false,
    timeout: 60_000,
  },
});
