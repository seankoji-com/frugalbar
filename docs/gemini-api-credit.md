# Gemini API prepaid credit for a Google AI Studio key's billing account

Investigation date: 20 November 2026 (Australia/Sydney).

## What this is

A paid-tier Google AI Studio key can be billed through an AI Studio Cloud
Billing account. The balance belongs to that billing account, shared by every
project and key on it, not to the key itself. The account carries:

- a **prepay balance** in the account's own currency, drawn down by Gemini API
  usage. Google documents that the billing lag can overdraw it, so AI Studio
  can show a negative balance;
- a recurring **Google Developer Program credit** (the Google AI Pro / Ultra
  monthly grant), converted from USD to the billing account's currency at
  redemption ([Developer Program benefits FAQ](https://developers.google.com/profile/help/benefits)).
  Once a positive prepay balance has unlocked them, eligible Google
  Cloud credits are consumed before the prepay funds (see Google's
  [Gemini API billing page](https://ai.google.dev/gemini-api/docs/billing));
- an optional **monthly spend cap** on the project, which stops paid requests
  when reached.

These are balances and limits, not quota windows. They are the only figures a
Gemini API key's account publishes instead of a usage percentage.

## Can FrugalBar measure them?

No, using a Gemini API key and a documented API. Three surfaces were checked:

1. **The Gemini API itself** (`generativelanguage.googleapis.com`, authenticated
   with `x-goog-api-key`) serves models, interactions, files, batches, cached
   content and agents. Its [API reference](https://aistudio.google.com/api-reference)
   has no billing, credit or spend operation.
2. **AI Studio's Billing documentation** states that the prepay balance is
   managed in AI Studio and that "all balance management and transaction
   history for the Gemini API must be done directly within the Google AI Studio
   Billing tab". The docs also direct users to `Dashboard > Usage` for usage
   monitoring; that is the AI Studio interface, not a documented API.
3. **The Cloud Billing API** exposes billing accounts, budgets, services and
   SKU prices. It does not expose a prepay credit balance, and Google's billing
   documentation says the prepay balance can only be managed in AI Studio. A
   Gemini API key also grants no billing IAM scope.

There is therefore no measured source. A figure guessed from a request count,
from the spend cap, or from the key's model traffic would be invented — the one
thing `AGENTS.md` forbids.

## What FrugalBar does instead

`GeminiAPICredit` records the figures the account holder reads from AI Studio's
Billing tab and enters in **Settings → Antigravity → Gemini API prepaid credit**. It holds:

| Field | Meaning | Where it comes from |
|---|---|---|
| Currency | The billing account's currency (ISO 4217) | The account |
| Prepaid balance | Prepay credit left after usage; may be negative in the billing lag | AI Studio → Billing |
| Monthly credit | The recurring Developer Program grant, in the account's currency | AI Studio → Billing |
| Monthly spend cap | The project's spend limit | AI Studio → Billing |

Settings records all three figures. The popover draws only the spend cap, as
the account's **API credit** line under the **Gemini** row inside the
**Antigravity** service block. The prepaid balance and monthly credit remain
Settings values and are not drawn.

The spend cap is drawn as its own line in the same anatomy as Codex's separate
monthly credit: the title and cap in the name column, one bar across the meter
area, and the percentage and countdown beneath. The bar's fill is **elapsed
calendar time**, never spend. Google publishes no spend figure for a Gemini API
key, and the prepaid balance is a separate pool drawn down after the monthly
grant, so neither can serve as the numerator. The visible figure is `MO 63%`;
the tooltip and VoiceOver label say "63% of the calendar month elapsed", and
the countdown says how many days are left in the month. The line uses the
informational colour and draws no quota pace marker.

For example, a project with an A$30 monthly spend cap records that cap as an
A$30 API credit line; the bar shows where in the calendar month you are, not a
percentage of the A$30 spent.

## What it is not

- **Not a measured vendor balance.** Nothing in the line claims a poll produced
  it. The tooltip says when the cap was saved.
- **Not a quota.** It never reaches `consumptionFraction`, urgency, exhaustion
  sorting, the advice engine, the menu-bar icon, the widget's average or the
  sync export.
- **Not a spend bar.** The API credit meter is elapsed calendar time. It draws
  no percentage of the cap spent, because a balance with no measured usage has
  no spend numerator. The prepaid balance and monthly credit are not drawn in
  the popover at all.
- **Not balance history.** It is not an `APICreditEntry`, so `BalanceSeries`
  never charts it. A configured number recorded as a vendor history point would
  be a reading from no observation.
- **Not staleable or retained.** It is attached to the Gemini snapshot on read
  from `GeminiAPICreditStore`, not stored in the poll cache, so a failed
  Antigravity poll neither erases it nor marks it stale — and a figure change in
  Settings shows immediately, without waiting out the poll floor.

Only the Gemini row hosts it. The AI Studio key is a Gemini API surface, not
the Argon pool or the shared Claude/GPT pool, and a key that serves both does
not move the same credit onto either of those rows.

## Regression coverage

- `GeminiAPICreditTests` — figure validation (including a negative prepay
  balance), whole-field amount parsing (a prefix such as "30abc" is refused),
  decode validation, store round-trip in a scratch suite, and the proof that
  the field contributes no balance series and changes no quota figure.
  `MoneyTextTests` covers the negative figure's sign outside the symbol.
- `GeminiAPICreditManagerTests` — attached to Gemini only, attached on read
  without another poll, shown when quota is unavailable, retained through a
  failed poll, hidden with the Gemini provider, and carried as no
  `apiCredits` entry.
- `GeminiAPICreditPlacementTests` — the spend cap drawn as a calendar-month
  API credit line (percentage, countdown and spoken wording), the fill proven
  independent of the prepaid balance and monthly credit, the balances absent
  from the drawn line, spoken on measured and unavailable rows, drawn below the
  row, the budget line's own height, and the Antigravity grouping left
  unchanged.

The attach-on-read path was proven red by removing the Gemini guard (the
Argon row then carried the credit) and by carrying the figure in `apiCredits`
(the engine test then found a balance series). The amount parser was proven red
by accepting any text and letting `Decimal(string:)` read a prefix ("30abc"
became 30). All mutations were reverted.
