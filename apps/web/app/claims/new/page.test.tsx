import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, test, vi } from "vitest";

import NewClaimPage from "./page";

vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }) }));

afterEach(() => vi.restoreAllMocks());

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
