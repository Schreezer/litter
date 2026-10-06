# Course chat composer

Scope: the existing SwiftUI course-chat input area. The user requested the supplied rounded, two-row composer with fewer controls. Navigation, conversation layout, and OS keyboard remain native.

## Evidence

- Source: `/var/folders/xm/lt06m0vj609_vzwd19kx0p080000gp/T/codex-clipboard-aed38cdd-b859-4085-9dc4-10dc3db845c6.png`.
- Implementation: `artifacts/composer/dark-keyboard.png` and `artifacts/composer/light-keyboard.png`.
- Focused comparison: `artifacts/composer/reference-detail.png` and `artifacts/composer/dark-detail.png`.
- Both full captures are 1320 × 2868 pixels, representing 440 × 956 native points at 3× density. No CSS viewport applies. The same 1320 × 360 crop at x=0, y=1490 isolates the composer and keyboard edge without scaling.
- State: portrait, focused empty input, keyboard open. Full source and implementation images were inspected together, followed by the focused crops. Light mode was checked separately.

## Comparison history

1. The old composer had three separate controls in one row and a boxed text field. Replaced it with a single rounded card, borderless input above, and attachment plus send/stop controls below.
2. The first test's dark-mode label was incorrect: the app theme left the chat sheet light. The fixture now explicitly sets the app appearance preference before loading its course and asserts dark mode in the UI test. Fresh captures confirmed a charcoal card and dark keyboard, followed by a light-mode relaunch.
3. Tightened the empty card from 100 to 92 points high to match the reference proportions.
4. The native placeholder was too dim on the charcoal background. Changed it to the system secondary-label color. Post-change full and focused captures confirm the brighter placeholder in both themes.

## Fidelity checks

- Typography: native SF body text, regular weight, matching the reference hierarchy. The brighter secondary-label placeholder remains readable on both backgrounds.
- Spacing: 12-point outer margins, 28-point continuous corners, a 92-point empty card, full-width input, and 44-point action targets. The composer stays above the keyboard.
- Colors: charcoal in dark mode, adaptive white in light mode, subtle outline, blue active send/stop control. Empty send is disabled gray because it sends text; the reference's blue empty-state button starts voice.
- Assets: native SF Symbols for plus, send, and stop. No raster assets or copied device chrome.
- Copy: course-specific placeholder and accessibility labels. Voice and mode controls are intentionally omitted per the user's request.

## Verification

- Course-reading UI flow passed with page context, send, dismiss, next-page navigation, and dark/light keyboard captures.
- Source-menu, preparing/disabled controls, passage context, and attachment-error recovery checks passed.
- Tests use local fixtures; live-provider inference and physical-device behavior are outside this layout verification.
- Final build and UI test passed: `/tmp/learnfold-composer-appearance.xcresult`. Source-menu and error-state evidence: `/tmp/learnfold-rounded-composer.xcresult`.
- Final full-view and focused comparison found no actionable P0/P1/P2 mismatch within the requested input-area scope. Small differences in OS keyboard styling are outside app-owned content.

final result: passed

---

# Landing page product proof

Scope: replace the landing page's illustrated product claim with current Learnfold iOS screens and align the surrounding copy with the capabilities those screens demonstrate.

## Evidence

- Source visual direction: the existing editorial landing system in `services/website/public/index.html` and `services/website/public/landing.css` (Newsreader/DM Sans/DM Mono, paper and ink palette, cobalt/coral/yellow accents, hard offset shadows).
- Simulator source captures: `output/landing-page-audit-2026-09-18/07-sourdough-source-prompt.png`, `08-course-brief-review.png`, `10-starter-learning-path.png`, `11-starter-first-lesson.png`, and `12-starter-ask-ai.png`.
- Shipped web assets: `services/website/public/assets/app/`.
- Implementation preview: `http://127.0.0.1:4174/` in the Codex in-app browser.

## Comparison history

1. Replaced the hand-built hero course illustration with an overlapping pair of real iOS captures: the learning path and page-context Ask AI sheet.
2. Added a four-part product tour showing source input, explicit course-plan review, a native lesson, and contextual questions. Kept the existing editorial palette and typography instead of restyling the page around the app's dark UI.
3. Cropped the plan-review capture at presentation time to focus on the production course-brief card and remove unrelated harness chrome.
4. Rewrote the four-step capability story and the alternate experiment copy to describe only the visible flow. The prewritten interactive example remains explicitly labeled as an example.

## Fidelity checks

- Typography and visual language: existing site tokens and type scale are preserved; screenshot captions use the site's mono eyebrow style.
- Layout: desktop hero keeps copy and product proof balanced; the product tour uses a two-column staggered grid. At 390px it becomes a single readable column and the hero montage remains inside the viewport.
- Assets: all product imagery is from the current native iOS build running in Simulator. Alt text describes the meaningful screen content.
- Copy: source input, course-brief review, structured course pages, and page-context questions match the screens shown. The page includes an AI fallibility note.
- Interaction: both copy variants retain identical product imagery, navigation anchors work, and the existing rabbit-hole demo remains functional.

## Verification

- Desktop visual pass at the default 1280 × 720 in-app-browser viewport for variants A and B.
- Mobile visual pass at 390 × 844 for the hero and product tour, then the viewport override was reset.
- Browser console: no warnings or errors.
- `npm test`: 13/13 passing with the local Pages worker running.
- `npm run check`: TypeScript, generated Cloudflare types, and JavaScript syntax checks passed.
- The live Hosted course-generation attempt did not confirm delivery, so no screenshot from that failed response is used or described as successful generation.

final result: passed
