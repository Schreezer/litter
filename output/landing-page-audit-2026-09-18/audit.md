# Learnfold landing-page audit

Date: 2026-09-18  
Scope: current local landing page plus a freshly built iPhone 17 Pro simulator run of the iOS app.

## Executive recommendation

Keep the curiosity-led positioning, but replace illustrative proof with the real product loop: **start with a topic or source → review the course brief → learn from the first generated page → ask, branch, or edit → generate the rest when useful**.

The landing page currently explains the philosophical idea well. It undersells the product's strongest concrete capabilities and makes the polished browser-style mockup look like the product. The native app is more distinctive: it gives the learner a reviewable plan, a persistent learning path, an editable lesson, and contextual follow-up.

## Suggested hero

**Eyebrow:** A course that grows with every question  
**Headline:** Turn curiosity into a course you can shape.  
**Body:** Something catches your attention. Learnfold helps you understand it, then follow the questions it creates. Start with a topic, document, or link; review the plan; then learn, ask, and edit as the course unfolds.  
**Primary CTA:** See the real app  
**Secondary CTA:** Join the waitlist

Use a real generated lesson as the dominant hero image, with two smaller annotated frames behind it: the course plan and the learning path. Move the current piano/guitar illustration into a later explanatory section.

## Recommended page order

1. **Hero with real app proof** — concise positioning, the real iOS lesson, and a CTA that scrolls to the product walkthrough.
2. **From curiosity to course** — three real frames: prompt/source, reviewable course brief, generated learning path.
3. **Learn by asking** — show a selected passage leading to an answer, improved lesson, or linked explainer page.
4. **Make it yours** — show native editing and explain that the learner can revise the course rather than accepting a sealed AI output.
5. **Control and trust** — explain plan approval, on-demand generation, persistence, and that AI can make mistakes. Keep provider details out of the hero.
6. **Short FAQ and waitlist** — retain the strongest existing FAQ content and remove repeated explanations of the rabbit-hole metaphor.

The current Difference, How it unfolds, Interactive demo, Workspace, and Subjects sections repeat the same core promise. Replace Difference and Subjects with real product proof; keep a shorter interactive example only if it is restyled to resemble the native app.

## High-priority changes

### 1. Stop leading with “Less scrolling”

That copy introduces a guilt/productivity frame that is weaker than the approved curiosity proposition. Learnfold's differentiator is not that it reduces scrolling; it turns a question into a course the learner can inspect, reshape, and deepen.

### 2. Show the approval moment

The current page jumps from a question to a nested page. The app has a more persuasive trust mechanism: it creates a course brief with an outcome, starting point, gaps, time estimate, and nested path before building the course. Show this explicitly as “Review the plan before Learnfold builds.”

### 3. Show that the course is living, not merely generated

Feature the learning path, on-demand chapter generation, contextual Ask AI action, and native editor. Together they substantiate “grows with your curiosity” better than another paragraph about rabbit holes.

### 4. Bridge the visual gap

The editorial beige/serif landing aesthetic can remain as the brand wrapper, but add a dark “Inside Learnfold” section that uses the app's actual black, blue, rounded, native iOS visual language. The current browser-style course window implies a different product.

### 5. Use a relatable real course for launch assets

The current build contains a real persisted zk-SNARKs course, but it is too specialist for the main hero and the library also contains internal QA titles. Capture a clean, successful course about sourdough, music, starlight, or another everyday curiosity. Show the complete receipt: prompt → brief → approval → first page.

## Current app evidence

- [Course library](./01-course-library-isolated.png) — persistent courses, continue-learning state, progress, and course metadata.
- [Generated learning path](./02-course-learning-path-isolated.png) — course structure, generated first chapter, later chapters, and course-agent entry point.
- [Generated lesson](./03-generated-lesson-isolated.png) — native long-form lesson rendering and contextual Ask AI action.
- [Native page editor](./04-native-page-editor-isolated.png) — direct editing of a generated page.
- [Live request in progress](./06-live-course-request.png) — a genuine hosted request was sent during this audit, but the app could not later confirm server acceptance. Treat this as diagnostic evidence, not marketing proof.

The first four captures were retaken on a dedicated `Learnfold Landing Capture` simulator and no longer contain the Fit Snap return-to-app breadcrumb. They remain product evidence rather than final campaign assets because the library contains internal course names. Recapture a relatable end-to-end course after one hosted request completes reliably.

## Accessibility observations

Strengths found in the current landing implementation:

- Skip link, semantic navigation and heading structure.
- Visible keyboard focus styles and reduced-motion handling.
- The interactive example announces state changes and moves focus to the new page title.
- Mobile interactive controls are sized around normal touch-target guidance.

Risks to test before launch:

- On a 390 × 844 viewport, the hero's product proof starts below the first screen; the value proposition is visible, but the app is not.
- Verify the mobile menu and nested demo with VoiceOver and keyboard navigation; DOM semantics alone are not conformance proof.
- Check muted eyebrow/microcopy contrast, 320 px layouts, and 200% zoom across every experiment variant.
- Keep decorative annotations out of the accessibility tree and give each real screenshot an outcome-focused alternative description.

## Walkthrough health

1. **Landing hero and mobile layout — mixed.** Clear positioning and working CTAs; real product proof is absent above the fold on mobile.
2. **Interactive rabbit-hole example — healthy but illustrative.** Interaction, focus transfer, and announcements worked; it does not mirror the native product's full workflow.
3. **Native library, learning path, lesson, and editor — healthy.** Fresh local build and simulator launch succeeded; existing persisted course content rendered correctly.
4. **Selected-passage follow-up — blocked in this run.** The persisted course was tied to an unavailable Hermes provider, so the flow could not produce a clean response.
5. **New hosted course request — needs attention.** A real request reached the thinking state, but the app later reported that it could not prove acceptance. No successful generated course is claimed from this attempt.
