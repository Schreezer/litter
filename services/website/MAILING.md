# Waitlist email

The mail integration uses AWS SES in us-east-1 with sender `Learnfold <chirag@forgeme.xyz>` and replies to `chirag@forgeme.xyz`. The domain is verified and all three DKIM records resolve through Cloudflare DNS. Existing iCloud MX and SPF records are preserved.

AWS SES in us-east-1 has production access. At setup inspection, only fitsnap.fun was verified. Cloudflare also manages forgeme.xyz; the site already lists chirag@forgeme.xyz as its contact. The owner selected Learnfold <chirag@forgeme.xyz>. SES reports verification and DKIM SUCCESS; bounce/complaint feedback forwarding is enabled.

New signups create one mail_outbox row in the same D1 transaction as the waitlist entry when MAIL_ENABLED=true. The learnfold-mail Worker runs each minute and sends a plain-text welcome through SES. Website requests never wait for AWS. Duplicate signups do not enqueue another message or restore an unsubscribed entry.

AWS credentials belong only in the mail Worker's secrets. scripts/configure-mail-credentials.py provisions a separate IAM principal restricted to ses:SendEmail for the chosen identity and From address. Do not copy the administration/root credentials into Cloudflare. The script refuses to replace existing access keys.

Deployment and recovery procedure:

1. Verify the chosen sender domain in SES us-east-1, including DKIM DNS records. Confirm account production sending remains enabled.
2. Set MAIL_FROM to `Learnfold <chosen-address>`, MAIL_REPLY_TO to the monitored contact, MAIL_REGION=us-east-1 in mail-worker/wrangler.toml. Keep MAIL_ENABLED=false initially.
3. Apply D1 migration 0003 locally and remotely. Deploy the disabled mail Worker, then install scoped credentials with scripts/configure-mail-credentials.py.
4. Test SES using success@simulator.amazonses.com, including a controlled D1 outbox fixture. SES MessageId proves acceptance, not inbox receipt. Do not send fixture emails to example.com.
5. Set MAIL_ENABLED=true in both the Pages vars and mail Worker vars. Update privacy copy to disclose Amazon SES processing and unsubscribe behavior before deploying both surfaces.
6. Verify a controlled live signup and unsubscribe round trip. Exclude simulator fixtures from experiment conversion data and remove only those fixtures afterward.

Mail states: pending, sending, accepted, failed, uncertain, cancelled. Accepted means SES returned a MessageId. Explicit 429/503 rejection retries up to five attempts with backoff. A timeout, missing response ID, or interrupted send becomes uncertain and requires reconciliation before any resend. Errors contain status codes, never message bodies or subscriber addresses. No automatic retry of ambiguous sends.

Unsubscribe links show a confirmation page on GET so email scanners cannot remove subscriptions. POST handles the button and email clients' one-click unsubscribe. A 72-character random token authorizes only that subscription; responses contain no address. Pending email is cancelled. An email already in flight may still arrive. Exports exclude unsubscribed entries. SES account suppression handles hard bounces and complaints; check suppression before any future campaign. No campaign or bulk-send feature is enabled.

Read queue status privately:

```sh
npx wrangler d1 execute EXPERIMENTS --remote --command "SELECT state,count(*) FROM mail_outbox GROUP BY state"
```

Signup conversion continues to mean a saved, consented email address. This welcome flow does not verify email ownership and does not change the experiment denominator.

Validation: npm run check; npm test with local wrangler Pages dev on port 4174; npx wrangler deploy --config mail-worker/wrangler.toml --dry-run. Keep local MAIL_ENABLED disabled so tests cannot send email.

## Production verification, September 9, 2026

Pages deployment: https://13c7f8b3.learnfold.pages.dev. Mail Worker version: bc89199c-e46f-494c-b331-2712cb0be336. MAIL_ENABLED=true on both services. Scoped IAM principal learnfold-waitlist-mail holds only ses:SendEmail for identity forgeme.xyz and From address chirag@forgeme.xyz.

A live signup to success@simulator.amazonses.com, submitted twice with DNT, created one queue row and no experiment conversion. The scheduled worker received SES MessageId 010001a085d3004e-3a322b6b-0f0b-4fb8-b487-8917ec1d2f76-000000 on its first attempt. This proves SES acceptance through the deployed pipeline, not delivery to a human inbox. GET unsubscribe preserved the subscription; POST recorded unsubscription. Only the simulator fixture was removed afterward. All 13 local tests and type checks passed.
