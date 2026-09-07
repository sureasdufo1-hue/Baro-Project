import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, test, vi } from "vitest";

import DocumentsPage from "./page";

vi.mock("next/navigation", () => ({
  useParams: () => ({ claimId: "claim-1" }),
  useSearchParams: () => new URLSearchParams(),
}));

afterEach(() => vi.restoreAllMocks());

test("selects a document type and reports an independent upload result", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn().mockImplementation(async (_url: string, init?: RequestInit) => ({
      json: async () => [],
      ok: true,
      status: init?.method === "POST" ? 201 : 200,
    })),
  );
  const { container } = render(<DocumentsPage />);
  await waitFor(() => expect(fetch).toHaveBeenCalled());
  fireEvent.change(screen.getByLabelText("문서 종류"), { target: { value: "OTHER" } });
  const input = container.querySelector("input[type=file]") as HTMLInputElement;
  const file = new File(["%PDF-1.4\n%%EOF"], "evidence.pdf", { type: "application/pdf" });
  fireEvent.change(input, { target: { files: [file] } });
  await waitFor(() => expect(screen.getByText(/안전하게 등록되었습니다/)).toBeTruthy());
  expect(screen.getByText("문서 분석 시작")).toBeTruthy();
});
