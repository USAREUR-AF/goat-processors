// SPDX-License-Identifier: Apache-2.0
//
// A reader on the local listener without the token: the page shows
// everything, offers no change, and the API refuses a change forced through.

import { test, expect } from "@playwright/test";

test.describe("reader, on the local listener without a token", () => {
  test("may look; every change is disabled, and the runner refuses one forced through", async ({ page }) => {
    await page.goto("/ui");
    await expect(page.locator("#who")).toContainText("Signed in as local");
    await expect(page.locator("#who")).toContainText("You may look");
    for (const name of ["Pick packs", "Pause", "Resume"]) {
      await expect(page.getByRole("button", { name, exact: true })).toBeDisabled();
    }
    await expect(page.locator("#tracks .be-row").first()).toContainText("Track");
    // The page holds no authority: a call made anyway is refused by the API, and
    // the refusal is shown in the error component with what to do.
    await page.evaluate(() => window.BE.call("stop").catch((e) => window.BE.error(document.getElementById("error"), e)));
    await expect(page.locator("#error")).toContainText("needs the role operate");
    await expect(page.locator("#error")).toContainText("run the command with sudo");
  });
});
