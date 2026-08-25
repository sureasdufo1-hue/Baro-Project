import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";

for (const route of ["/", "/login", "/register"] as const) {
  test(`${route} has no critical or serious accessibility violations`, async ({ page }) => {
    await page.goto(route);
    const results = await new AxeBuilder({ page })
      .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
      .analyze();
    const blocking = results.violations.filter(
      (violation) => violation.impact === "critical" || violation.impact === "serious",
    );
    expect(blocking).toEqual([]);
  });
}

test("landing page keeps its primary hierarchy on mobile", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: /복잡한 보험금 분석/ })).toBeVisible();
  await expect(page.getByRole("link", { name: /보험금 분석 시작/ })).toBeVisible();
  await expect(page.getByAltText(/AI 보험 도우미/)).toBeVisible();
  // The pipeline menu and its detail card can render the same label.
  await expect(page.getByText("문서 업로드", { exact: true }).first()).toBeVisible();
});

test("login is keyboard operable and exposes labelled controls", async ({ page }) => {
  await page.goto("/login");
  await page.getByLabel("이메일").focus();
  await expect(page.getByLabel("이메일")).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(page.getByLabel("비밀번호")).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(page.getByRole("button", { name: "로그인" })).toBeFocused();
});
