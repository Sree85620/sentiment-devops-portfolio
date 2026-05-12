/**
 * testing/k6_load_test.js
 *
 * k6 Load Test — AI Sentiment API
 * ─────────────────────────────────────────────────────────────────────────────
 * Install k6 on Ubuntu:
 *   sudo gpg -k && sudo gpg --no-default-keyring \
 *     --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
 *     --keyserver hkp://keyserver.ubuntu.com:80 \
 *     --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
 *   echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] \
 *     https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
 *   sudo apt update && sudo apt install k6
 *
 * Run:
 *   k6 run k6_load_test.js
 *
 * With HTML report (requires xk6-reporter or k6 cloud):
 *   k6 run --out json=results.json k6_load_test.js
 *
 * Stages:
 *   0:00 → 0:30  Ramp up   : 0 → 20 VUs
 *   0:30 → 2:30  Sustained : 20 VUs (stress the API)
 *   2:30 → 3:00  Ramp down : 20 → 0 VUs
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// ── Custom Metrics ─────────────────────────────────────────────────────────
const errorRate       = new Rate('sentiment_error_rate');
const responseLatency = new Trend('sentiment_response_latency', true); // true = milliseconds
const requestCount    = new Counter('sentiment_requests_total');
const jsonParseErrors = new Counter('sentiment_json_parse_errors');

// ── Test Configuration ─────────────────────────────────────────────────────
export const options = {
  stages: [
    { duration: '30s', target: 20 },   // Ramp up to 20 VUs
    { duration: '2m',  target: 20 },   // Hold 20 VUs — sustained load
    { duration: '30s', target: 0  },   // Ramp down gracefully
  ],

  thresholds: {
    // 95th percentile response time must be under 2 seconds
    'http_req_duration':            ['p(95)<2000'],
    // Custom latency trend
    'sentiment_response_latency':   ['p(95)<2000'],
    // Error rate must stay below 5%
    'sentiment_error_rate':         ['rate<0.05'],
    // HTTP errors must stay below 5%
    'http_req_failed':              ['rate<0.05'],
  },

  // Mimic browser-like connection behaviour
  noConnectionReuse: false,
  userAgent: 'k6-SentimentLoadTest/1.0 (UK-DevOps-Portfolio)',
};

// ── Target ─────────────────────────────────────────────────────────────────
const BASE_URL = __ENV.BASE_URL || 'http://localhost:30005';

// ── Test Payloads (rotated across VUs) ────────────────────────────────────
const PAYLOADS = [
  "I absolutely love this product — outstanding quality!",
  "Terrible service. Completely disappointed. Would not recommend.",
  "It was decent, nothing special. Average experience overall.",
  "WOW!!! Can't believe it's FREE?! #Amazing & @Incredible — 100% off!",
  "Café au lait était délicieux! 😍🎉 Très magnifique, wirklich wunderbar!",
  "The team was incredibly helpful and the response time was phenomenal.",
  "Absolute rubbish — broken on arrival, customer service non-existent.",
  "Not bad, not great. Somewhere in the middle. Could be improved.",
  "Best purchase of 2024! Ten out of ten, would buy again immediately.",
  "Never using this again. Complete waste of money and time.",
];

// ── Default HTTP params ────────────────────────────────────────────────────
const PARAMS = {
  headers: { 'Content-Type': 'application/json' },
  timeout: '10s',
};

// ── VU Function (runs once per iteration per VU) ──────────────────────────
export default function () {
  // Each VU picks a different payload based on its ID to maximise coverage
  const payload = PAYLOADS[(__VU - 1) % PAYLOADS.length];

  group('Sentiment API — POST /v1/sentiment', () => {
    const body = JSON.stringify({ text: payload });
    const startTime = Date.now();

    const res = http.post(`${BASE_URL}/v1/sentiment`, body, PARAMS);

    const latency = Date.now() - startTime;
    responseLatency.add(latency);
    requestCount.add(1);

    // ── Assertions ─────────────────────────────────────────────────────
    const passed = check(res, {
      'HTTP status is 200':          (r) => r.status === 200,
      'Response time < 2000ms':      (r) => r.timings.duration < 2000,
      'Response is not empty':       (r) => r.body && r.body.length > 0,
      'Content-Type is JSON':        (r) => {
        const ct = r.headers['Content-Type'] || '';
        return ct.includes('application/json') || ct.includes('text/json');
      },
      'Response body contains score or sentiment': (r) => {
        try {
          const json = JSON.parse(r.body);
          return (
            json.score !== undefined        ||
            json.sentiment !== undefined    ||
            json.label !== undefined        ||
            (json.output && json.output.score !== undefined)
          );
        } catch {
          jsonParseErrors.add(1);
          return false;
        }
      },
    });

    // Track error rate
    errorRate.add(!passed);
  });

  // Realistic think time: 0.5–1.5s between requests per VU
  sleep(0.5 + Math.random());
}

// ── Lifecycle hooks ────────────────────────────────────────────────────────
export function setup() {
  console.log(`🚀 k6 Load Test Starting`);
  console.log(`   Target      : ${BASE_URL}`);
  console.log(`   Max VUs     : 20`);
  console.log(`   Duration    : ~3 minutes`);
  console.log(`   Payloads    : ${PAYLOADS.length} rotating strings`);

  // Smoke test before load
  const res = http.get(BASE_URL, { timeout: '5s' });
  if (res.status === 0) {
    console.error(`❌ API unreachable at ${BASE_URL} — aborting.`);
    // k6 will abort if setup throws
    throw new Error(`API not reachable: ${BASE_URL}`);
  }
  console.log(`✅ API smoke test passed (${res.status})\n`);
}

export function teardown(data) {
  console.log('\n════════════════════════════════════════════');
  console.log(' k6 Load Test Complete');
  console.log('════════════════════════════════════════════');
  console.log(' Check thresholds above for pass/fail status');
  console.log(' Results: k6 run --out json=results.json k6_load_test.js');
  console.log('════════════════════════════════════════════');
}
