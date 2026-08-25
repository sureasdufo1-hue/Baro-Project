import { expect, test, type Page } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Real-stack reviewer journey: a claim that lands in MANUAL_REVIEW is created,
// a SYSTEM_ADMIN opens and assigns the review through the API, and an ADJUSTER
// works it through the admin UI (accept -> request documents -> approve ->
// complete) while the user submits the requested document and resumes the
// review from the web UI. Requires the full compose stack running.
test.setTimeout(25 * 60_000);

const diagnosisFixture = path.resolve(__dirname, "fixtures", "diagnosis-certificate.png");
// A distinct file: the domain rejects re-registering an identical file per claim.
const opinionFixture = path.resolve(__dirname, "fixtures", "medical-opinion.png");
const staffPassword = "ReviewE2eStaff2026!";
// Per-run staff accounts keep the adjuster queue free of stale reviews.
const stamp = Date.now();
const adminEmail = `reviewer-e2e-admin-${stamp}@example.com`;
const adjusterEmail = `reviewer-e2e-adjuster-${stamp}@example.com`;

function dockerExec(args: string): string {
  return execSync(`docker compose exec -T ${args}`, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

let adjusterId = "";

test.beforeAll(() => {
  dockerExec(
    `-e BOOTSTRAP_ADMIN_EMAIL=${adminEmail} -e BOOTSTRAP_ADMIN_PASSWORD=${staffPassword} ` +
      `-e BOOTSTRAP_ADJUSTER_EMAIL=${adjusterEmail} -e BOOTSTRAP_ADJUSTER_PASSWORD=${staffPassword} ` +
      `api python scripts/bootstrap_admin.py`,
  );
  adjusterId = dockerExec(
    `postgres psql -U claimlens -d claimlens -t -A -c "SELECT user_id FROM users WHERE email='${adjusterEmail}'"`,
  ).trim();
  expect(adjusterId).toMatch(/^[0-9a-f-]{36}$/);
});

// Claim subpages live at /claims/{id}/...; derive the claim base from any
// current URL so navigation works from verification/documents pages too.
function claimBase(page: Page): string {
  const match = new URL(page.url()).pathname.match(/\/claims\/[^/?]+/);
  if (!match) throw new Error(`Not on a claim page: ${page.url()}`);
  return match[0];
}

// The verification page renders previously verified facts immediately, so
// poll with reloads until at least one unverified fact (확인 button) shows up.
async function waitUntilFactsPending(page: Page): Promise<void> {
  const pending = page.locator("article.fact").filter({
    has: page.getByRole("button", { name: "확인" }),
  });
  await expect(async () => {
    if ((await pending.count()) === 0) await page.reload();
    await expect(pending.first()).toBeVisible();
  }).toPass({ timeout: 12 * 60_000 });
}

async function confirmAllFacts(page: Page): Promise<void> {
  // Local OCR commonly misreads I21.0 as 21.0; the user corrects it once.
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
}

test("expert reviews a manual-review claim through the admin UI", async ({ browser, page, request }) => {
  const email = `reviewer-journey-${stamp}@example.com`;
  const password = "E2eReviewerUser2026!";
  const policyNumber = `E2E-REVIEWER-${stamp}`;

  // ---- Part 1: user creates a claim that lands in MANUAL_REVIEW ----
  await page.goto("/register");
  await page.getByLabel("이름").fill("검토여정E2E");
  await page.getByLabel("이메일").fill(email);
  await page.getByLabel("비밀번호").fill(password);
  await page.getByRole("button", { name: "가입하기" }).click();
  await page.waitForURL("**/login");
  await page.getByLabel("이메일").fill(email);
  await page.getByLabel("비밀번호").fill(password);
  await page.getByRole("button", { name: "로그인" }).click();
  await page.waitForURL("**/dashboard");

  await page.goto("/insureds/new");
  await page.getByLabel("이름").fill("김검토");
  await page.getByRole("button", { name: "저장" }).click();
  await page.waitForURL("**/contracts/new");

  await page.getByLabel("보험회사").selectOption({ label: "DB손해보험" });
  const productSelect = page.getByLabel("보험상품");
  await productSelect.selectOption({ label: "무배당 프로미라이프 참좋은훼밀리종합보험" });
  await page.getByLabel("상품 Version").selectOption({ label: "2401" });
  await page.getByLabel("피보험자").selectOption({ label: "김검토" });
  await page.getByLabel("증권번호").fill(policyNumber);
  await page.getByLabel("보장개시일").fill("2024-01-01");
  await page.getByLabel("만기일").fill("2054-01-01");

  // 급성심근경색 has executable rules; 암주요치료비 has none and therefore
  // forces its assessment into MANUAL_REVIEW.
  const row1 = page.locator(".coverage-row").nth(0);
  await row1.locator("select").selectOption({ label: "급성심근경색증진단비" });
  await row1.getByPlaceholder("가입금액(원)").fill("30000000");
  await page.getByRole("button", { name: "담보 추가" }).click();
  const row2 = page.locator(".coverage-row").nth(1);
  await row2.locator("select").selectOption({ label: "암주요치료비(연간1회한)" });
  await row2.getByPlaceholder("가입금액(원)").fill("10000000");
  await page.getByRole("button", { name: "계약 저장" }).click();
  await page.waitForURL("**/contracts/*");
  await expect(page.getByRole("heading", { name: "보험계약 상세" })).toBeVisible();

  await page.goto("/claims/new");
  await page.locator("select[name=contract]").selectOption({ index: 1 });
  await page.getByLabel("Case 제목").fill("E2E 전문가검토 여정");
  await page.getByLabel("진단일").fill("2026-08-10");
  await page.getByLabel("증상/발병일").fill("2026-08-01");
  await page.getByLabel("내용").fill("E2E: 급성 심근경색(I21.0) 진단 검토 여정");
  await page.getByRole("button", { name: "Case 생성하고 다음 단계로" }).click();
  await page.waitForURL(/\/claims\/[^/?]+\?created=1/);
  const claimId = new URL(page.url()).pathname.match(/\/claims\/[^/?]+/)![0].split("/")[2];

  await page.getByRole("link", { name: "문서 등록 및 관리" }).click();
  await page.setInputFiles('input[type="file"]', diagnosisFixture);
  await expect(page.getByText("diagnosis-certificate.png · 안전하게 등록되었습니다.")).toBeVisible({
    timeout: 120_000,
  });
  await page.getByRole("button", { name: "문서 분석 시작" }).click();
  await expect(page.getByText("분석 작업이 등록되었습니다.", { exact: false })).toBeVisible();

  await page.getByRole("link", { name: "분석상태 / 정보확인" }).click();
  await expect(page.getByRole("heading", { name: "문서 분석 및 정보확인" })).toBeVisible();
  await waitUntilFactsPending(page);
  await confirmAllFacts(page);

  await page.goto(`${claimBase(page)}/assessments`);
  await page.getByRole("button", { name: "담보 분석 실행" }).click();
  await expect(page.getByText("지급요건 충족")).toBeVisible({ timeout: 180_000 });
  await expect(page.getByText("전문가 검토 필요")).toBeVisible();
  await page.goto(claimBase(page));
  await expect(page.getByText("MANUAL_REVIEW")).toBeVisible();

  // ---- Part 2: SYSTEM_ADMIN creates and assigns the review via API ----
  const login = await request.post("http://localhost:8000/api/auth/login", {
    data: { email: adminEmail, password: staffPassword },
  });
  expect(login.ok()).toBeTruthy();
  const created = await request.post("http://localhost:8000/api/reviews", {
    data: {
      claim_id: claimId,
      review_type: "GENERAL_CLAIM_REVIEW",
      reason: "E2E: 룰이 없는 담보에 대한 전문가 검토",
    },
  });
  expect(created.status()).toBe(201);
  const review = (await created.json()) as { review_id: string };
  const assigned = await request.post(
    `http://localhost:8000/api/reviews/${review.review_id}/assign`,
    { data: { reviewer_user_id: adjusterId } },
  );
  expect(assigned.ok()).toBeTruthy();

  // ---- Part 3: adjuster accepts and requests additional documents ----
  const adjusterContext = await browser.newContext();
  const adjusterPage = await adjusterContext.newPage();
  await adjusterPage.goto("/login");
  await adjusterPage.getByLabel("이메일").fill(adjusterEmail);
  await adjusterPage.getByLabel("비밀번호").fill(staffPassword);
  await adjusterPage.getByRole("button", { name: "로그인" }).click();
  await adjusterPage.waitForURL("**/dashboard");

  await adjusterPage.goto("http://localhost:3001/reviews");
  await expect(adjusterPage.getByRole("heading", { name: "전문가 Review Dashboard" })).toBeVisible();
  await expect(adjusterPage.getByText("ASSIGNED").first()).toBeVisible();
  await adjusterPage.getByRole("link", { name: "검토 열기" }).first().click();
  await expect(adjusterPage.getByRole("heading", { name: "Claim Review" })).toBeVisible();

  await adjusterPage.getByRole("button", { name: "검토 시작" }).click();
  await expect(adjusterPage.getByText("처리되었습니다.")).toBeVisible();
  await expect(adjusterPage.getByText("IN_PROGRESS").first()).toBeVisible();

  await adjusterPage.getByLabel("판단불가/자료요청 사유").fill("E2E: 추가 진단 확인서가 필요합니다");
  await adjusterPage.getByRole("button", { name: "추가자료 요청" }).click();
  await expect(adjusterPage.getByText("ADDITIONAL_DOCUMENT_REQUIRED").first()).toBeVisible();

  // ---- Part 4: user submits the requested document and resumes the review ----
  await page.goto(`${claimBase(page)}/review`);
  await expect(page.getByText("추가 확인이 필요합니다")).toBeVisible();
  await page.getByRole("link", { name: "서류 제출하기" }).click();
  await expect(page.getByText("전문가가 요청한 추가 서류")).toBeVisible();
  await page.setInputFiles('input[type="file"]', opinionFixture);
  await expect(page.getByText("medical-opinion.png · 안전하게 등록되었습니다.")).toBeVisible({
    timeout: 120_000,
  });
  await page.getByRole("button", { name: "문서 분석 시작" }).click();
  await expect(page.getByText("분석 작업이 등록되었습니다.", { exact: false })).toBeVisible();

  await page.getByRole("link", { name: "분석상태 / 정보확인" }).click();
  await expect(page.getByRole("heading", { name: "문서 분석 및 정보확인" })).toBeVisible();
  await waitUntilFactsPending(page);
  await confirmAllFacts(page);

  await page.goto(`${claimBase(page)}/review`);
  await page.getByRole("button", { name: "검토 재개 요청" }).click();
  await expect(page.getByText("전문가 검토가 재개되었습니다.")).toBeVisible({ timeout: 30_000 });
  await expect(page.getByText("IN_PROGRESS").first()).toBeVisible();

  // ---- Part 5: adjuster approves and completes the review ----
  await adjusterPage.reload();
  await expect(adjusterPage.getByText("IN_PROGRESS").first()).toBeVisible();
  await adjusterPage.getByLabel("전문가 의견").fill("제출된 추가 서류로 판단 가능합니다");
  await adjusterPage.getByRole("button", { name: "승인" }).click();
  await expect(adjusterPage.getByText("APPROVED").first()).toBeVisible();
  await adjusterPage.getByRole("button", { name: "검토 완료" }).click();
  await expect(adjusterPage.getByText("COMPLETED").first()).toBeVisible();

  // ---- Part 6: user sees the completed review and claim ----
  await page.goto(`${claimBase(page)}/review`);
  await expect(page.getByText("COMPLETED").first()).toBeVisible();
  await page.goto(claimBase(page));
  await expect(page.locator("span.status", { hasText: "COMPLETED" })).toBeVisible();

  await adjusterContext.close();
});
