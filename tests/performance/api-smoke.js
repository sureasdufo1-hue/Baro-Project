import http from "k6/http";
import { check } from "k6";

export const options = { vus: 5, duration: "30s" };
const baseUrl = __ENV.BASE_URL || "http://localhost:8000";

export default function () {
  const live = http.get(`${baseUrl}/health/live`);
  check(live, { "liveness is 200": (response) => response.status === 200 });
  const ready = http.get(`${baseUrl}/health/ready`);
  check(ready, { "readiness is 200": (response) => response.status === 200 });
}
