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
// FrugalBar's own bracketed read is not reported as the page's fetch.
await window.fetch(response(endpoint), { credentials: 'same-origin', frugalbarOwnRead: true });
assert.equal(messages.length, 2);

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const run = new AsyncFunction('fetch', 'query', 'AbortController', 'setTimeout', 'clearTimeout', refresh);
let timer, cleared;
const setTimer = (callback, milliseconds) => {
  assert.equal(milliseconds, 4000);
  timer = callback;
  return 1;
};
const clearTimer = id => { assert.equal(id, 1); cleared = true; };
const accountUUID = '11111111-1111-4111-8111-111111111111';
const account = { uuid: accountUUID, email_address: 'private@example.test', full_name: 'Private' };
// One evaluation reads the account, then billing, then the account again.
const calls = [];
const options = [];
const stub = (billing = () => ({ ok: true, json: async () => payload }),
              who = () => ({ ok: true, status: 200, json: async () => account })) => async (url, opts) => {
  calls.push(url);
  options.push(opts);
  return url === '/api/account' ? who(calls.length) : billing();
};
const result = JSON.parse(await run(stub(), '/fixture', AbortController, setTimer, clearTimer));
assert.deepEqual(calls, ['/api/account', '/fixture', '/api/account']);
assert.deepEqual(result.before, { uuid: accountUUID });
assert.deepEqual(result.after, { uuid: accountUUID });
// The account crosses as its UUID only: no email or name.
assert.equal(JSON.stringify(result).includes('private@example.test'), false);
assert.equal(result.billing.monthly_credit_usd, '12.34');
assert.equal('private_account_field' in result.billing, false);
assert.equal('granted_total_usd' in result.billing, false);
assert.ok(options.every(o => o.credentials === 'same-origin' && o.signal.aborted === false));
assert.equal(options[1].frugalbarOwnRead, true);
timer();
assert.ok(options.every(o => o.signal.aborted === true));
assert.equal(cleared, true);
// HTTP failure never forwards an error body as entitlement data.
calls.length = 0;
const failure = JSON.parse(await run(stub(() => ({ ok: false, headers: { get: () => '600' } })),
  '/fixture', AbortController, setTimer, clearTimer));
assert.deepEqual(failure.billing, { _retryAfter: '600' });
// A signed-out session reports it, and a failed account read is null, never a guess.
calls.length = 0;
const signedOut = JSON.parse(await run(stub(undefined, n => n === 1
  ? { ok: false, status: 401 } : { ok: false, status: 500 }), '/fixture', AbortController, setTimer, clearTimer));
assert.deepEqual(signedOut.before, { signedOut: true });
assert.equal(signedOut.after, null);
// Timer cleanup also runs when fetching or reading the billing body throws,
// and the failure is reported as a failed read rather than thrown.
for (const billing of [
  () => { throw new Error('offline fixture'); },
  () => ({ ok: true, json: async () => { throw new Error('invalid fixture'); } }),
]) {
  cleared = false;
  calls.length = 0;
  const thrown = JSON.parse(await run(stub(billing), '/fixture', AbortController, setTimer, clearTimer));
  assert.deepEqual(thrown.billing, { _failed: true });
  assert.equal(cleared, true);
}
console.log('Production WebKit scripts passed: field projection, account bracketing, origin/path filters, generation, HTTP failure, abort and cleanup');
