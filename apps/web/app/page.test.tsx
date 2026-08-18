import { render, screen } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import LandingPage from "./page";

vi.mock("next/link", () => ({ default: ({ children }: { children: React.ReactNode }) => children }));

test("describes the foundation scope", () => {
  render(<LandingPage />);
  expect(screen.getByText(/보험금 계산 기능은 아직 구현되지 않았습니다/)).toBeTruthy();
});

