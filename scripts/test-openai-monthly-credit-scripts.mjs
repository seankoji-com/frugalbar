// Exercise the production OpenAI billing observer offline. No web session,
// no credentials, and no request is performed.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = fs.readFileSync(
  new URL('../Sources/QuotaBarCore/Providers/OpenAIMonthlyCreditSession.swift', import.meta.url), 'utf8');
const observer = source.match(/private static let observer = #"""([\s\S]*?)"""#/)[1]
  .replaceAll('__SESSION_GENERATION__', 'test-generation');

const messages = [];
function XMLHttpRequest() {}
XMLHttpRequest.prototype.open = function () {};
const headersRead = [];
const response = (url, body, type = 'application/json') => ({
  url,
  headers: {
    get: name => {
      headersRead.push(name);
      return name === 'content-type' ? type : null;
    },
  },
  clone: () => ({ json: async () => body }),
});
const window = {
  fetch: async response => response,
  webkit: { messageHandlers: { openAIMonthlyCredit: { postMessage: body => messages.push(body) } } },
};
vm.runInNewContext(observer, { window, XMLHttpRequest });

const payload = {
  object: 'credit_summary',
  total_granted: 230,
  total_used: 12.34,
  total_available: 187.66,
  private_account_field: 'excluded',
  grants: { object: 'list', data: [{
    id: 'grant-private-id',
    object: 'credit_grant',
    grant_amount: 200,
    used_amount: 12.34,
    effective_at: '2026-10-19T00:25:31Z',
    expires_at: '2026-11-19T00:25:31Z',
    grant_type: 'promotion',
    private_field: 'excluded',
  }] },
};
const endpoint = 'https://api.openai.com/dashboard/billing/credit_grants';
const originalResponse = response(endpoint, payload);

const returned = await window.fetch(originalResponse);
assert.equal(returned, originalResponse, 'the wrapper must return the page response unchanged');
assert.equal(messages.length, 1);
assert.equal(messages[0].generation, 'test-generation');
const projected = JSON.parse(messages[0].payload);
assert.equal(projected.grants.length, 1);
assert.equal(projected.grants[0].grant_amount, 200);
assert.equal(projected.grants[0].used_amount, 12.34);
assert.equal(projected.grants[0].expires_at, '2026-11-19T00:25:31Z');
assert.equal('total_available' in projected, false);
assert.equal('private_account_field' in projected, false);
assert.equal('id' in projected.grants[0], false);
assert.equal('private_field' in projected.grants[0], false);
assert.deepEqual(headersRead, ['content-type'], 'only the content type may be inspected');

// A non-billing URL and a non-JSON body are ignored.
await window.fetch('https://api.openai.com/v1/models');
await window.fetch(response(endpoint, payload, 'text/html'));
await window.fetch(response('https://api.openai.com/dashboard/credit', payload));
assert.equal(messages.length, 1);

// An empty summary is still forwarded: it is how a vanished grant clears the
// row instead of leaving the old figure on screen.
await window.fetch(response(endpoint, { object: 'credit_summary' }));
assert.equal(messages.length, 2);
assert.deepEqual(JSON.parse(messages[1].payload), { grants: [] });

// A page route (HTML) is never mistaken for the grants response.
await window.fetch(response('https://platform.openai.com/settings/organization/billing/credit-grants',
  payload, 'text/html'));
assert.equal(messages.length, 2);

console.log('Production OpenAI billing observer passed: generation, projection, field minimization, URL and content-type filters');
