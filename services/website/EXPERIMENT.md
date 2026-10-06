# Learnfold landing copy test

The September 18, 2026 test (v3) compares a product-literal headline with a scrolling-to-learning message inspired by [Curiosity Quench](https://www.curiosityquench.com/). It does not copy that product's claims, design, testimonials, ratings, or user counts. v3 replaced the v2 copy and page design on September 18, 2026, so v2 data is not comparable and stays under its own experiment ID until retention removes it.

| | A: Product-literal | B: Less scrolling |
|---|---|---|
| Headline | Turn any question into a course. | Less scrolling. More understanding. |
| Motivation | Bring a question, link, or document; the course grows as you ask. | Give something you would scroll past the time to become understanding. |
| Product | A course that grows through questions and linked pages. | The same course behavior. |

Only the marked copy changes (hero headline, lede and focus line; the mid-page "why" card; the closing card). Layout, demo examples, navigation, waitlist form, consent and CTA destinations remain shared. This tests the overall copy direction; it cannot isolate the effect of one sentence.

## Measurement

- Eligible browsers are assigned 50/50 with Web Crypto. An HttpOnly, first-party cookie keeps the assignment for 30 days. Cross-device visits and cleared cookies count as different browsers.
- The primary metric is unique browsers completing a new waitlist signup divided by unique exposed browsers. A conversion is recorded in the same transaction as the new email entry. Duplicate emails never produce another conversion. This measures saved signups, not verified mailbox ownership, installs or active learners.
- Exposure is recorded when the document is visible. A click also confirms exposure so network ordering cannot produce a numerator without a denominator.
- The secondary metric is unique browsers choosing a question in the interactive demo. Merely scrolling to the demo does not count.
- Repeat events are deduplicated in D1. Unknown events, other origins, forced previews, known bot user agents, prefetches, DNT and GPC headers are excluded. This is basic bot filtering, not proof that every remaining visit is human.
- Only the configured production hostname measures traffic. Cloudflare deployment aliases remain untracked. Use the normal root URL for campaigns; forced-variant preview links are never measurement links.
- Experiment records store a hashed random token, assigned copy, and event timestamps. The separate waitlist table stores email, consent version and signup attribution. Analytics never receives emails, IP addresses, full referrers, user agents, or browsing histories. Infrastructure providers still process request metadata as described in the privacy policy.
- Assignment failure serves A without counting the request. Measurement failure does not block navigation. Disabled JavaScript or blocked measurement requests can cause undercounting.
- Records are excluded from reporting after 90 days and pruned during later site use. Save a report when ending the test.

## Preview

- [A preview](https://learnfold.pages.dev/?variant=a)
- [B preview](https://learnfold.pages.dev/?variant=b)

Previewing does not enroll a browser, overwrite an existing assignment, or record events. A and B retain canonical metadata for the main URL; previews have a noindex response header.

## Read results

From `services/website`, run:

```sh
npm ci
npm run report
python3 scripts/experiment-report.py --json
```

The report reads real production D1 rows using your authenticated Cloudflare CLI. It has no public administration endpoint and never seeds counts. `--local` reads disposable local test data instead.

Use the same campaign URL and acquisition channels for both variants. Review after at least two complete weeks, then inspect visitor counts, allocation balance, conversion rates and their uncertainty intervals. Sparse traffic stays inconclusive. The report deliberately declares no automatic winner, and its per-arm Wilson intervals are descriptive, not a sequential significance test. Do not repeatedly peek and announce the first temporary lead as a result.

## Development and checks

```sh
npm ci
npm run check
npx wrangler d1 migrations apply EXPERIMENTS --local
```

Create an ignored `.dev.vars` file with:

```text
COPY_EXPERIMENT_MODE=active
COPY_EXPERIMENT_HOST=127.0.0.1
WAITLIST_RATE_SALT=use-a-random-local-secret
```

Run `npm run dev`, then `npm test` in another terminal. Integration tests refuse a non-loopback target and write only local D1 data. Use `python3 scripts/experiment-report.py --local` to inspect those fixtures.

## Deploy or stop

Apply migrations to the dedicated production experiment database before the first Functions deployment:

```sh
npx wrangler d1 migrations apply EXPERIMENTS --remote
npm run deploy
```

Only `public/` and the compiled Pages Functions are published. Tests, reports, generated types and local configuration are outside the public directory.

To stop assignment and measurement, change `COPY_EXPERIMENT_MODE` to `off` in `wrangler.toml`, regenerate types, and redeploy. This serves A to everyone, including previously assigned B browsers. Save the final real report first. Changing either variant's copy requires a new experiment ID and cookie name so old data is not mixed with a new test.

## Waitlist operations

The active test is `learning-motivation-waitlist-v3`, using `lf_copy_v3`. v3 started because the landing page copy and visual design were replaced on September 18, 2026. Save the v2 report before deploying v3; prior v1 and v2 data remain in D1 until normal retention removes them.

The shared form validates email and explicit consent on the server. It uses an invisible honeypot, a maximum request size, same-origin checks, and ten valid submission attempts per IP per hour. IP limits use a secret-keyed hash; raw IPs are not stored. The production `WAITLIST_RATE_SALT` is a Pages secret. Use `wrangler pages secret put WAITLIST_RATE_SALT --project-name learnfold` when rotating it. Do not rotate casually because that resets active rate limits.

A successful signup means the email was stored. A welcome email is queued through AWS SES for each new signup; mailbox ownership is not verified. Email delivery failures do not remove the saved signup. Preview pages can accept genuine signups, but do not attribute them to either variant. DNT/GPC visitors can also sign up without experiment attribution.

Read counts with `python3 scripts/waitlist.py`. Export addresses with `python3 scripts/waitlist.py --export /absolute/private/path/waitlist.csv`. The export is private, protected by Cloudflare authentication, and uses owner-only file permissions. Never put exports under `public/` or commit them. Handle removal requests through the authenticated database; remove matching waitlist records and associated analytics records using the stored anonymous identifier when applicable.

## PostHog

Set `POSTHOG_PROJECT_KEY` and the corresponding `POSTHOG_HOST` in `wrangler.toml`, regenerate types and deploy. The public project token is sufficient for ingestion. Creating a dashboard through the API additionally requires project management access. Until a key is configured, anonymous events remain in the D1 outbox and the local report continues to work.

The server forwards `landing_viewed`, `waitlist_cta_clicked`, `demo_engaged`, and `waitlist_joined`, each tagged with `experiment`, `variant`, and `source=learnfold_landing`. Only the first occurrence per participant is queued. D1 triggers enqueue events atomically; failed delivery remains pending and retries on later production visits or submissions. A stable event UUID deduplicates retries. Pending and delivered rows expire after 90 days. Low traffic can delay retries; there is no scheduled delivery worker.

In PostHog, create a funnel from `landing_viewed` to `waitlist_joined`, filter `experiment = learning-motivation-waitlist-v3`, break down by `variant`, and use unique users with a 30-day conversion window. Add trends for unique `demo_engaged` and `waitlist_cta_clicked` events with the same filter. Assignment stays server-side; do not add a second PostHog feature flag that re-randomizes it. Compare with the D1 report, which counts any conversion during the assignment lifetime. Funnel windows and report date filters can produce differences.

No autocapture, session replay, person profiles, email identification or IP forwarding is enabled. Dashboard results remain inconclusive until enough real visitors and conversions accumulate; no winner is declared automatically.

## Connected dashboard

PostHog project `601129` is connected on the US free plan. The saved dashboard is [Learnfold: landing conversion and app usage](https://us.posthog.com/project/601129/dashboard/2079342), with [landing conversion](https://us.posthog.com/project/601129/insights/o6BGvZrf) and [iOS usage](https://us.posthog.com/project/601129/insights/YiwqQZW3) panels. The landing panel uses the last 90 days and the current experiment ID. App usage uses the last 30 days. Both queries read actual events; setup checks use a different experiment/event and are excluded.

The production waitlist save, deduplication, variant attribution and server outbox delivery were verified on September 9, 2026. Reserved-address signup fixtures and their experiment records were removed after verification. The explicitly named PostHog `integration_check` event is setup evidence, not a visitor or conversion.

## AWS email integration

The queued welcome-email implementation and deployment steps are documented in [MAILING.md](MAILING.md). Sender: Learnfold <chirag@forgeme.xyz>, verified in AWS SES us-east-1. The mail Worker polls the durable queue every minute.
