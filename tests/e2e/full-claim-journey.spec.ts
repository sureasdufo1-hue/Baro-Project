import { expect, test, type Page } from "@playwright/test";
import path from "node:path";

// Real-stack browser journey: register -> contract -> claim -> upload
// -> OCR/AI (local providers) -> fact verification -> assess -> calculate
// -> result with evidence chain. Requires the full compose stack running.
test.setTimeout(25 * 60_000);

const diagnosisFixture = path.resolve(__dirname, "fixtures", "diagnosis-certificate.png");

// Claim subpages live at /claims/{id}/...; derive the claim base from any
// current URL so navigation works from verification/documents pages too.
function claimBase(page: Page): string {
  const match = new URL(page.url()).pathname.match(/\/claims\/[^/?]+/);
  if (!match) throw new Error(`Not on a claim page: ${page.url()}`);
  return match[0];
}

test("user completes an insurance claim journey end to end", async ({ page }) => {
  // Unique per attempt so a retry never reuses an already-registered email.
  const stamp = Date.now();
  const email = `e2e-browser-${stamp}@example.com`;
  const password = "E2eBrowserUser2026!";
  const policyNumber = `E2E-BROWSER-${stamp}`;

  // 1. Register
  await page.goto("/register");
  await page.getByLabel("이름").fill("브라우저E2E");
  await page.getByLabel("이메일").fill(email);
  await page.getByLabel("비밀번호").fill(password);
  await page.getByRole("button", { name: "가입하기" }).click();
  await page.waitForURL("**/login");

  // 2. Login
  await page.getByLabel("이메일").fill(email);
  await page.getByLabel("비밀번호").fill(password);
  await page.getByRole("button", { name: "로그인" }).click();
  await page.waitForURL("**/dashboard");

  // 3. Insured
  await page.goto("/insureds/new");
  await page.getByLabel("이름").fill("홍길동");
  await page.getByRole("button", { name: "저장" }).click();
  await page.waitForURL("**/contracts/new");

  // 4. Contract with two subscribed coverages
  await page.getByLabel("보험회사").selectOption({ label: "DB손해보험" });
  const productSelect = page.getByLabel("보험상품");
  await productSelect.selectOption({ label: "무배당 프로미라이프 참좋은훼밀리종합보험" });
  await page.getByLabel("상품 Version").selectOption({ label: "2401" });
  await page.getByLabel("피보험자").selectOption({ label: "홍길동" });
  await page.getByLabel("증권번호").fill(policyNumber);
  await page.getByLabel("보장개시일").fill("2024-01-01");
  await page.getByLabel("만기일").fill("2054-01-01");

  const row1 = page.locator(".coverage-row").nth(0);
  await row1.locator("select").selectOption({ label: "급성심근경색증진단비" });
  await row1.getByPlaceholder("가입금액(원)").fill("30000000");
  await page.getByRole("button", { name: "담보 추가" }).click();
  const row2 = page.locator(".coverage-row").nth(1);
  await row2.locator("select").selectOption({ label: "허혈성심장질환진단비" });
  await row2.getByPlaceholder("가입금액(원)").fill("10000000");

  await page.getByRole("button", { name: "계약 저장" }).click();
  await page.waitForURL("**/contracts/*");
  await expect(page.getByRole("heading", { name: "보험계약 상세" })).toBeVisible();
  await expect(page.getByText("급성심근경색증진단비")).toBeVisible();
  await expect(page.getByText("허혈성심장질환진단비")).toBeVisible();

  // 5. Claim
  await page.goto("/claims/new");
  await page.locator("select[name=contract]").selectOption({ index: 1 });
  await page.getByLabel("Case 제목").fill("E2E 브라우저 급성심근경색 진단비 청구");
  await page.getByLabel("진단일").fill("2026-08-10");
  await page.getByLabel("증상/발병일").fill("2026-08-01");
  await page.getByLabel("내용").fill("E2E: 급성 심근경색(I21.0) 진단");
  await page.getByRole("button", { name: "Case 생성하고 다음 단계로" }).click();
  await page.waitForURL(/\/claims\/[^/?]+\?created=1/);
  await expect(page.getByText("DOCUMENT_REQUIRED")).toBeVisible();

  // 6. Upload diagnosis certificate and start analysis
  await page.getByRole("link", { name: "문서 등록 및 관리" }).click();
  await page.setInputFiles('input[type="file"]', diagnosisFixture);
  await expect(page.getByText("diagnosis-certificate.png · 안전하게 등록되었습니다.")).toBeVisible({
    timeout: 120_000,
  });
  await page.getByRole("button", { name: "문서 분석 시작" }).click();
  await expect(page.getByText("분석 작업이 등록되었습니다.", { exact: false })).toBeVisible();

  // 7. Fact verification (waits through real OCR + local LLM extraction)
  await page.getByRole("link", { name: "분석상태 / 정보확인" }).click();
  await page.waitForSelector("article.fact", { timeout: 12 * 60_000 });

  let modifiedDiagnosisCode = false;
  for (let round = 0; round < 40; round += 1) {
    const pending = page.locator("article.fact").filter({
      has: page.getByRole("button", { name: "확인" }),
    });
    if ((await pending.count()) === 0) break;
    const fact = pending.first();
    const factType = (await fact.locator("strong").innerText()).trim();
    const shownValue = (await fact.locator("p").first().innerText()).replace(/\s+/g, "");
    if (factType === "DIAGNOSIS_CODE" && shownValue !== "I21.0" && !modifiedDiagnosisCode) {
      modifiedDiagnosisCode = true;
      page.once("dialog", (dialog) => void dialog.accept("I21.0"));
      await fact.getByRole("button", { name: "수정" }).click();
    } else {
      await fact.getByRole("button", { name: "확인" }).click();
    }
    await page.waitForTimeout(700);
  }
  expect(
    await page
      .locator("article.fact")
      .filter({ has: page.getByRole("button", { name: "확인" }) })
      .count(),
  ).toBe(0);
  expect(await page.locator("article.fact").count()).toBeGreaterThan(0);

  // 8. Coverage assessment
  await page.goto(`${claimBase(page)}/assessments`);
  await page.getByRole("button", { name: "담보 분석 실행" }).click();
  await expect(page.getByText("지급요건 충족")).toBeVisible({ timeout: 180_000 });
  await expect(page.getByText("지급요건 미충족")).toBeVisible();

  // 9. Deterministic calculation per assessment
  await page.goto(`${claimBase(page)}/calculations`);
  const calcButtons = page.getByRole("button", { name: "계산", exact: true });
  // The page renders one button per assessment after its fetch resolves.
  await expect(calcButtons.first()).toBeAttached({ timeout: 30_000 });
  const calcCount = await calcButtons.count();
  expect(calcCount).toBeGreaterThan(0);
  for (let index = 0; index < calcCount; index += 1) {
    await calcButtons.nth(index).click();
    await expect(page.getByText("계산이 완료되었습니다.")).toBeVisible();
  }
  await expect(page.getByRole("heading", { name: "30,000,000 KRW", exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "0 KRW", exact: true })).toBeVisible();
  await expect(page.getByText("CALCULATED · V1").first()).toBeVisible();

  // Evidence chains must be built before the result totals them: the API sums
  // only evidence-complete calculations and completes the claim once all are.
  const basisLinks = page.getByRole("link", { name: "계산 근거 보기" });
  await expect(basisLinks.first()).toBeAttached({ timeout: 30_000 });
  const basisCount = await basisLinks.count();
  for (let index = 0; index < basisCount; index += 1) {
    await basisLinks.nth(index).click();
    // Wait for the basis page data to load before probing for the build button;
    // while fetching, neither the button nor the existing chain is rendered.
    await expect(page.getByRole("heading", { name: "담보별 상세결과" })).toBeVisible({
      timeout: 30_000,
    });
    const buildButton = page.getByRole("button", { name: "근거사슬 생성" });
    if (await buildButton.isVisible().catch(() => false)) {
      await buildButton.click();
      // On success the whole "chain needed" section (message included) unmounts;
      // a failed build keeps it visible with an error message.
      await expect(page.getByRole("heading", { name: "계산 근거 준비 필요" })).toBeHidden({
        timeout: 30_000,
      });
    }
    await page.goto(`${claimBase(page)}/calculations`);
  }

  // 10. Result with evidence chain
  await page.getByRole("link", { name: "보험금 분석결과" }).click();
  await expect(page.getByRole("heading", { name: "보험금 분석결과" })).toBeVisible();
  await expect(page.locator(".result-total strong")).toHaveText("30,000,000원");
  await expect(page.getByText(/COMPLETED/).first()).toBeVisible();
  await expect(page.locator("article.card strong.amount", { hasText: "30,000,000원" })).toBeVisible();

  await page
    .locator("article.card", { hasText: "30,000,000원" })
    .getByRole("link", { name: "계산 근거 보기" })
    .click();
  await expect(page.getByRole("heading", { name: "담보별 상세결과" })).toBeVisible();
  await expect(page.getByText("예상 보험금 30,000,000원")).toBeVisible();
  await expect(page.getByText("가입금액 Snapshot 30,000,000원")).toBeVisible();

  const buildButton = page.getByRole("button", { name: "근거사슬 생성" });
  if (await buildButton.isVisible().catch(() => false)) {
    await buildButton.click();
    await expect(buildButton).toBeHidden();
  }
  await expect(page.getByRole("heading", { name: "적용 약관" })).toBeVisible();
  await expect(page.getByRole("link", { name: "원문 약관 보기" }).first()).toBeVisible();
  await expect(page.getByRole("heading", { name: "사용한 의료정보" })).toBeVisible();
});
