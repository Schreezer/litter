# App Review notes and privacy answers (subscriptions)

Everything the owner needs to paste into App Store Connect for the Plus and Hosted subscriptions. Companion to `docs/design/paid-tier.md`.

## 1. Paste into App Review Information > Notes

```
Learnfold turns a topic or your own sources into a personal course. No sign-in is needed; the app has no accounts.

WHAT YOU CAN DO WITHOUT PAYING
- Launch the app and finish the short setup. Choose "Hosted" (or an Apple model if your device offers one). Setup never asks for payment.
- Open the library and read the bundled "practice course". It needs no AI agent and no purchase.
- Apple's on-device and Private Cloud Compute models are free forever on devices that support them.

WHERE THE PAYWALL IS
- Settings (gear) > Subscription > Plan > "See plans".
- Or: in the course screen, send any message while Hosted is the selected agent. The plan sheet appears. (A plan is needed only to send AI requests with Hosted or with your own runtime.)

SUBSCRIPTIONS (one group, "Learnfold Plans")
- Learnfold Plus, com.chirag.learnfold.plus.monthly: unlocks using your own runtime (Codex, Hermes, or your own API key and endpoint).
- Learnfold Hosted, com.chirag.learnfold.hosted.monthly: unlocks Learnfold's cloud Hosted agent. Includes everything in Plus.
- Prices and renewal terms are shown on the plan sheet in the App Store's localized format, with Restore Purchases, Manage Subscription, Terms of Use and Privacy Policy.

TESTING PURCHASES
- Subscribing works in the App Store sandbox and is free for you. Sandbox renewals are accelerated (a month renews in about 5 minutes). Use your sandbox Apple Account.
- After subscribing, the plan sheet closes by itself and Settings > Plan shows the plan name and renewal date. Hosted requests then work without any further step.
- Restore Purchases (plan sheet or Settings > Plan) recovers an existing subscription.

TESTING THE $1 PLUS PLAN (bring-your-own runtime)
- TODO(owner): supply a working demo endpoint before submitting. Plus only matters if the reviewer can connect a runtime, so give them one:
    Hermes endpoint: <TODO URL>        token: <TODO, expiring>
  or an OpenAI-compatible BYOK test key:
    Course Agent settings > Codex > custom provider
    Base URL: <TODO>   API key: <TODO, low-limit, revocable>
- Steps once you have it: open the course agent menu (Course Agent settings) > pick Hermes (or Codex with the key above) > subscribe to Plus when asked > send a message.

DATA AND PRIVACY
- Hosted sends your prompts and sources to Learnfold's cloud service and an AI model provider. This is stated in setup and in the privacy policy.
- Subscriptions are managed by RevenueCat using a pseudonymous ID. We do not receive name, email or Apple Account.
- Contact: chirag@fitsnap.fun
```

Replace every `TODO` before submitting, and rotate the demo token or key after review. Never put the RevenueCat secret key or a real production token in the notes.

## 2. What a reviewer sees before paying (finding)

Checked on this branch:

- The bundled practice course is app-authored and installs without an agent turn, but it installs only after setup completes (`installStarterCourseIfNeeded()` requires `setupComplete`).
- Before this branch's change, an enforced build gated agent selection at setup. A reviewer without Apple Intelligence, which is common on simulators and older iPhones, had only paid agents (Hosted, Codex, Hermes) and hit the paywall before seeing any content.
- Fixed: first-run setup is never paywalled (`CourseExperienceStore.connectLocalAgent`). Choosing Hosted completes setup locally, the library and practice course appear, and the first send opens the plan sheet. Covered by `testFirstRunSetupWithAPaidAgentIsNeverPaywalledAndShowsThePracticeCourse`.
- Not changed: after setup, selecting another paid agent in Settings opens the plan sheet, and every send path stays gated. Nothing is hard-blocked at launch.
- The Reviewer therefore sees real value (the practice course, the reading experience, free Apple models where available) and meets the paywall only when asking an AI agent to do work.

Residual risk: a reviewer on a device with no Apple Intelligence who sends a message needs a sandbox purchase or the demo runtime above to see an AI-generated course. The notes above cover both.

## 3. App Store Connect setup (per subscription)

- Group `Learnfold Plans`: Hosted level 1, Plus level 2. Group display name and localization filled in.
- Each product: reference name, product ID exactly as above, 1 month duration, price tier (the $1 and $5 you want; prices must not be hardcoded in the app), localized display name and description, and a review screenshot of the plan sheet (take it from the XCUITest attachment or a TestFlight build).
- App information: Privacy Policy URL `https://learnfold.pages.dev/privacy`. For the Terms of Use either add `https://learnfold.pages.dev/terms` as a custom EULA or add a "Terms of Use" link to the app description. The app's plan sheet already links both.
- Agreements, Tax and Banking complete; Paid Apps agreement active.
- Submit the two subscriptions with the app version for review (first-time subscriptions are reviewed with the binary).
- In-App Purchase key and App Store Connect API key uploaded to RevenueCat (see the owner checklist in the PR).

## 4. App Store privacy labels the owner must set

App Privacy > Data Types. Answer these for the version that ships RevenueCat. Items 1 and 2 are new with RevenueCat; the rest are already true and listed so the labels stay consistent with `PrivacyInfo.xcprivacy`.

| # | Data type (Apple category) | Collected | Linked to the user | Used to track | Purposes |
|---|---|---|---|---|---|
| 1 | Purchases > Purchase History | Yes | Yes | No | App Functionality |
| 2 | Identifiers > User ID | Yes | Yes | No | App Functionality |
| 3 | Identifiers > Device ID | Yes | Yes | No | App Functionality, Analytics |
| 4 | Usage Data > Product Interaction | Yes | Yes | No | Analytics |

Notes:

- 1 and 2 are RevenueCat (and, for the ID, the Hosted service). Purchase history is which products the pseudonymous ID holds and when. The ID is a one-way hash of an install secret, not a name, email or Apple ID. It counts as linked because it is a stable identifier tied to the subscription record, and the label should follow the stricter answer. RevenueCat's own bundled manifest says "not linked" for purchase history; Apple merges SDK and app manifests and the stricter app-level declaration governs.
- 3 is unchanged and comes from the analytics SDK. The RevenueCat SDK is configured with `automaticDeviceIdentifierCollectionEnabled = false`, so RevenueCat adds no device identifier (no IDFV or IDFA).
- 4 is unchanged (PostHog, anonymous feature-use events, opt-out in Settings).
- "Data Used to Track You": none. No data type is used for tracking, and the app does not request App Tracking Transparency.
- IP address is processed by RevenueCat and Cloudflare as network metadata and is not retained as a profile or location; Apple's categories have no IP entry. Re-check RevenueCat's current App Privacy guidance before submitting in case their wording changes.
- Hosted conversation content (prompts and sources sent to the cloud service and a model provider) is covered by the existing Other User Content declaration for Hosted, not changed here. Confirm that answer is still set to Collected for App Functionality.
- Name, email, payment info, contacts and location are not collected. Payment details stay with Apple.

## 5. Privacy manifest consistency

- `apps/ios/Sources/Litter/PrivacyInfo.xcprivacy` now declares User ID and Purchase History as linked, not tracking, App Functionality, in addition to the existing Device ID and Product Interaction. `NSPrivacyTracking` stays false with no tracking domains.
- RevenueCat 5.93.0 ships its own `PrivacyInfo.xcprivacy` (User Defaults `CA92.1`; Purchase History, App Functionality). The app already declares User Defaults `CA92.1`, so the reason set is consistent.
- Required Reason API scan of the built app binary: see `docs/releases/privacy-audit-2026-08-01.md` (addendum).
