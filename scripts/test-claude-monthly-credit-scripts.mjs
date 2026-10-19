// Exercise the production WebKit scripts offline. No web session or credentials.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = fs.readFileSync(new URL('../Sources/QuotaBarCore/Providers/ClaudeMonthlyCreditSession.swift', import.meta.url), 'utf8');
const observer = source.match(/private static let observer = #"""([\s\S]*?)"""#/)[1]
  .replaceAll('__SESSION_GENERATION__', 'test-generation');
const refresh = source.match(/private static let refreshQuery = #"""([\s\S]*?)"""#/)[1];
const payload = {
  status: 'linked', monthly_credit_usd: '12.34', next_grant_at: '2027-02-15T14:49:22Z',
  granted_total_usd: '999', private_account_field: 'excluded',
};
const messages = [];
const window = {
  fetch: async response => response,
  webkit: { messageHandlers: { monthlyCredit: { postMessage: body => messages.push(body) } } },
};
vm.runInNewContext(observer, { window, URL });
const response = (url, ok = true) => ({
  url, ok, clone: () => ({ json: async () => payload }), headers: { get: () => '600' },
});
const endpoint = 'https://claude.ai/api/quirky-lollipop/link-state?organization_uuid=fixture&include_candidates=false';
await window.fetch(response(endpoint));
assert.equal(messages.length, 1);
assert.equal(messages[0].generation, 'test-generation');
assert.equal(JSON.parse(messages[0].payload).monthly_credit_usd, '12.34');
assert.equal('private_account_field' in JSON.parse(messages[0].payload), false);
assert.equal('granted_total_usd' in JSON.parse(messages[0].payload), false);
for (const url of [
  endpoint.replace('claude.ai', 'other.test'),
  endpoint.replace('/link-state', '/other'),
  endpoint.replace('include_candidates=false', 'include_candidates=true'),
]) await window.fetch(response(url));
assert.equal(messages.length, 1);
await window.fetch(response(endpoint, false));
assert.equal(messages[1].retryAfter, '600');
assert.deepEqual(JSON.parse(messages[1].payload), { _failed: true });

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const run = new AsyncFunction('fetch', 'query', 'AbortController', 'setTimeout', 'clearTimeout', refresh);
let timer, cleared, options;
const setTimer = (callback, milliseconds) => {
  assert.equal(milliseconds, 4000);
  timer = callback;
  return 1;
};
const clearTimer = id => { assert.equal(id, 1); cleared = true; };
const result = await run(async (_, opts) => {
  options = opts;
  return { ok: true, json: async () => payload };
}, '/fixture', AbortController, setTimer, clearTimer);
assert.equal(JSON.parse(result).monthly_credit_usd, '12.34');
assert.equal('private_account_field' in JSON.parse(result), false);
assert.equal('granted_total_usd' in JSON.parse(result), false);
assert.equal(options.credentials, 'same-origin');
assert.equal(options.signal.aborted, false);
timer();
assert.equal(options.signal.aborted, true);
assert.equal(cleared, true);
// HTTP failure never forwards an error body as entitlement data.
const failure = await run(async () => ({ ok: false, headers: { get: () => '600' } }),
  '/fixture', AbortController, setTimer, clearTimer);
assert.deepEqual(JSON.parse(failure), { _retryAfter: '600' });
// Timer cleanup also runs when fetching or reading the body throws.
for (const fetch of [
  async () => { throw new Error('offline fixture'); },
  async () => ({ ok: true, json: async () => { throw new Error('invalid fixture'); } }),
]) {
  cleared = false;
  await assert.rejects(run(fetch, '/fixture', AbortController, setTimer, clearTimer));
  assert.equal(cleared, true);
}
console.log('Production WebKit scripts passed: field projection, origin/path filters, generation, HTTP failure, abort and cleanup');
