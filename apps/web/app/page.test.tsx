import { render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import LandingPage from "./page";

vi.mock("next/link", () => ({ default: ({ children }: { children: React.ReactNode }) => children }));

test("presents the insurance analysis journey", () => {
  render(<LandingPage />);
  expect(screen.getByRole("heading", { name: /복잡한 보험금 분석/ })).toBeTruthy();
  expect(screen.getByText("문서 업로드")).toBeTruthy();
  expect(screen.getByText("산정 근거 확인")).toBeTruthy();
  expect(screen.getByAltText(/AI 보험 도우미/)).toBeTruthy();
});
