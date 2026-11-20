// SPDX-License-Identifier: Apache-2.0
//
// The operator, signed in on the mesh listener with a client certificate.
// Drives every action of Fieldkit Processors against a running runner
// (start.py): view, pack use, stop, start, replay, explain, proposal approve,
// proposal reject. Each action is checked twice: on the page, and through the
// API the CLI uses, so the page cannot claim a change the runner did not make.

import { test, expect } from "@playwright/test";
import path from "node:path";

const VECTOR = path.resolve("../../../packs/correlate-assign-time/vectors/56-assign-time-offset-fit.json");

async function view(page) {
  // The same read the page makes, through the page's own origin and sign-in.
  const r = await page.request.get("/v1/view");
  expect(r.ok()).toBeTruthy();
  return r.json();
}

async function waitFor(page, check, what) {
  for (let i = 0; i < 60; i++) {
    const v = await view(page);
    if (check(v)) return v;
    await page.waitForTimeout(250);
  }
  throw new Error("timed out waiting for " + what);
}

test.describe.configure({ mode: "serial" });

test.describe("operator, signed in with a client certificate", () => {
  test.beforeEach(async ({ page }) => {
    await waitFor(page, (v) => v.proposals.length >= 2 && v.tracks.length >= 2, "tracks and the two proposals");
    await page.goto("/ui");
    await expect(page.locator("#who")).toContainText("Signed in as ops");
    await expect(page.locator("#who")).toContainText("You may change the runner");
  });

  test("view: the plan, the tracks, quality per source, the pipeline", async ({ page }) => {
    await expect(page.locator("#banner")).toHaveAttribute("data-state", "connected");
    await expect(page.locator("#plan circle.fp-track").first()).toBeVisible();
    expect(await page.locator("#plan circle.fp-track").count()).toBeGreaterThanOrEqual(2);
    await expect(page.locator("#plan circle.fp-track.fp-multi").first()).toBeVisible(); // a track joining two sources
    await expect(page.locator("#legend")).toContainText("radar-1");
    await expect(page.locator("#legend")).toContainText("adsb");
    await expect(page.locator("#tracks .be-row").first()).toContainText("Track");
    await expect(page.locator("#quality .be-row", { hasText: "radar-1" })).toContainText("reports:");
    await expect(page.locator("#quality .be-row", { hasText: "adsb" })).toBeVisible();
    await expect(page.locator("#pipeline")).toContainText("correlate");
    await expect(page.locator('[data-strip="view"] code')).toHaveText("goat-processors view");
  });

  test("pack use: pick a pack for one function", async ({ page }) => {
    await page.getByRole("button", { name: "Pick packs" }).click();
    await page.locator("#use-function").selectOption("quality");
    await page.locator("#use-pack").selectOption("quality-time");
    await expect(page.locator("#use-preview")).toContainText("quality will run pack quality-time instead of quality-feed");
    await expect(page.locator('[data-strip="use"] code')).toHaveText("goat-processors pack use quality quality-time");
    await page.locator("#use-go").click();
    const sheet = page.locator("dialog.be-sheet");
    await expect(sheet.locator(".be-cli code")).toHaveText("goat-processors pack use quality quality-time");
    await sheet.getByRole("button", { name: "Yes, use it" }).click();
    await expect(page.locator("#done")).toContainText("quality now runs pack quality-time");
    const v = await view(page);
    expect(v.pipeline.find((p) => p.function === "quality").pack).toBe("quality-time");
  });

  test("stop and start: pause and resume", async ({ page }) => {
    await page.getByRole("button", { name: "Pause" }).first().click();
    await expect(page.locator('[data-strip="run"] code')).toHaveText("goat-processors stop");
    await page.locator("#run-go").click();
    await page.locator("dialog.be-sheet").getByRole("button", { name: "Yes, pause" }).click();
    await expect(page.locator("#done")).toContainText("Paused");
    expect((await view(page)).status.state).toBe("paused");
    await page.getByRole("button", { name: "Now" }).click();
    await expect(page.locator("#banner")).toContainText("Paused");

    await page.getByRole("button", { name: "Resume" }).click();
    await expect(page.locator('[data-strip="run"] code')).toHaveText("goat-processors start");
    await page.locator("#run-go").click();
    await page.locator("dialog.be-sheet").getByRole("button", { name: "Yes, resume" }).click();
    await expect(page.locator("#done")).toContainText("Running again");
    expect((await view(page)).status.state).toBe("running");
  });

  test("replay: a file through a copy of the pipeline", async ({ page }) => {
    const before = await view(page);
    await page.getByRole("button", { name: "Replay a file" }).click();
    await page.locator("#replay-file").setInputFiles(VECTOR);
    await expect(page.locator('[data-strip="replay"] code')).toHaveText("goat-processors replay 56-assign-time-offset-fit.json --api");
    await page.locator("#replay-go").click();
    await expect(page.locator("#done")).toContainText("output lines");
    await expect(page.locator("#replay-out")).toContainText("Events, per function and event");
    await expect(page.locator("#replay-out")).toContainText("correlate");
    // The live runner did not change.
    const after = await view(page);
    expect(after.pipeline).toEqual(before.pipeline);
  });

  test("explain: one track's events and trace records", async ({ page }) => {
    const v = await view(page);
    const multi = v.tracks.find((t) => t.members.length >= 2);
    const id = multi.group || multi.system;
    await page.locator("#tracks .be-row", { hasText: "Track " + id }).getByRole("button", { name: "Explain" }).click();
    await expect(page.locator('[data-strip="explain"] code')).toHaveText("goat-processors explain " + id);
    await expect(page.locator("#explain-out h2").first()).toHaveText("Track " + id);
    await expect(page.locator("#explain-out")).toContainText("trace records name this track");
    expect(await page.locator("#explain-out table").count()).toBeGreaterThanOrEqual(1);
    await expect(page.locator("#explain-out table").last().locator("th").first()).toHaveText("step");
  });

  test("proposal approve and reject", async ({ page }) => {
    const v = await view(page);
    const waiting = v.proposals.filter((p) => p.state === "pending");
    expect(waiting.length).toBeGreaterThanOrEqual(2);
    const [first, second] = waiting;

    let row = page.locator("#proposals .be-row", { hasText: first.id });
    await row.getByRole("button", { name: "Approve" }).click();
    let sheet = page.locator("dialog.be-sheet");
    await expect(sheet.locator(".be-cli code")).toHaveText("goat-processors proposal approve " + first.id);
    await sheet.getByRole("button", { name: "Yes, approve" }).click();
    await expect(page.locator("#done")).toContainText("Proposal " + first.id);
    let now = await view(page);
    expect(now.proposals.find((p) => p.id === first.id).state).toBe("applied");
    expect(now.pipeline.find((p) => p.function === "correlate").pack).toBe(first.pack);

    row = page.locator("#proposals .be-row", { hasText: second.id });
    await row.getByRole("button", { name: "Reject" }).click();
    sheet = page.locator("dialog.be-sheet");
    await expect(sheet.locator(".be-cli code")).toHaveText("goat-processors proposal reject " + second.id);
    await sheet.getByRole("button", { name: "Yes, reject" }).click();
    await expect(page.locator("#done")).toContainText("Proposal " + second.id);
    now = await view(page);
    expect(now.proposals.find((p) => p.id === second.id).state).toBe("rejected");
  });

  test("the page makes no request outside the actions it declares", async ({ page }) => {
    const seen = [];
    page.on("request", (r) => seen.push(new URL(r.url()).pathname));
    await page.goto("/ui");
    await page.waitForTimeout(2500); // one live refresh
    const allowed = /^\/(ui|v1\/view)$/;
    expect(seen.filter((p) => !allowed.test(p))).toEqual([]);
  });
});
