import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, test, vi } from "vitest";

import NewClaimPage from "./page";

vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }) }));

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

const contract = {
  contract_id: "contract-1",
  insured_id: "insured-1",
  policy_number: "POL-001",
  contract_status: "ACTIVE",
  coverage_start_date: "2026-01-01",
  coverage_end_date: "2026-12-31",
};

test("branches between disease and injury accident fields", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({ json: async () => [], ok: true }),
  );
  render(<NewClaimPage />);
  await waitFor(() => expect(fetch).toHaveBeenCalled());
  expect(screen.getByLabelText("진단일")).toBeTruthy();
  fireEvent.click(screen.getByLabelText("상해"));
  expect(screen.getByLabelText("사고일")).toBeTruthy();
  expect(screen.queryByLabelText("진단일")).toBeNull();
  expect(screen.getByText(/문서로 확인된 사실이 아닙니다/)).toBeTruthy();
});

describe("contract API boundary", () => {
  test("renders a validated contract array", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ json: async () => [contract], ok: true }));
    render(<NewClaimPage />);
    expect(await screen.findByRole("option", { name: /POL-001/ })).toBeTruthy();
  });

  test("renders an empty state for an empty array", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ json: async () => [], ok: true }));
    render(<NewClaimPage />);
    expect(await screen.findByText(/등록된 보험계약이 없습니다/)).toBeTruthy();
  });

  test.each([401, 500])("renders an error state for HTTP %s", async (status) => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ json: async () => ({ detail: "error" }), ok: false, status }));
    render(<NewClaimPage />);
    expect((await screen.findByRole("alert")).textContent).toMatch(/불러오지 못했습니다/);
  });

  test("rejects malformed JSON shape without crashing", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ json: async () => ({ contracts: [contract] }), ok: true }));
    render(<NewClaimPage />);
    expect((await screen.findByRole("alert")).textContent).toMatch(/불러오지 못했습니다/);
  });
});
