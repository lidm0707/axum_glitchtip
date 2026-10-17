import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';

export const options = {
  stages: [
    { duration: '10s', target: 20 },
    { duration: '30s', target: 50 },
    { duration: '10s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<200'],
  },
};

export default function () {
  const health = http.get(`${BASE_URL}/health`);
  check(health, { 'health 200': (r) => r.status === 200 });

  const hit = http.get(`${BASE_URL}/api/hit`);
  check(hit, { 'hit 200': (r) => r.status === 200 });

  if (__ITER % 10 === 0) {
    http.get(`${BASE_URL}/api/error`);
  }
}
