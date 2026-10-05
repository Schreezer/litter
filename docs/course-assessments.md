# Lesson assessments

Lessons remain native `BlockDocument` records in the course SQLite library. Markdown is the authoring/import format. Reserved assessment fences render together under one "Test your understanding" section before the next-lesson action. The section is collapsed by default on each page, shows the optional-check count, and expands on tap. Collapsing it preserves drafts and active reviews. Exercises do not gate navigation.

Use real section headings (`## Explanation`, `## Worked example` or `## Scenario`, `## Exercise`) and short paragraphs with blank lines. Initial and subsequent lesson-generation prompts carry these instructions, including Hosted requests.

## Version 1 definitions

Put JSON inside a `learnfold-assessment` fence. Every definition has `version: 1`, a stable lowercase slug `id` unique on the page, `kind`, and `prompt`. `title` is optional.

```learnfold-assessment
{"version":1,"id":"oxygen-check","kind":"multiple_choice","prompt":"Which process depends directly on ATP?","options":[{"id":"storage","text":"DNA storage"},{"id":"pumps","text":"Ion pumping"}],"answer":{"option_id":"pumps","explanation":"ATP supplies energy for these pumps."}}
```

Multiple-choice checks have 2–5 distinct options and one matching answer ID. The answer and explanation stay inside the reserved fence.

```learnfold-assessment
{"version":1,"id":"explain-pumps","kind":"free_text","prompt":"Explain why ATP loss affects ion pumps.","rubric":["ATP supplies energy for ion pumping.","Reduced ATP impairs the pumps."]}
```

Free-text checks require a nonempty rubric of key ideas. Reviews should accept equivalent wording.

```learnfold-assessment
{"version":1,"id":"reason-together","kind":"discussion","prompt":"Reason through what happens when ATP falls.","opening_prompt":"What do the pumps need to keep working?","rubric":["Connect ATP supply to pump function."]}
```

Discussion checks optionally specify an opening question and rubric. Starting one creates an attempt without fabricating a learner answer or a mastery result.

Rust owns validation, fingerprints, deterministic choice grading, review linkage, and hidden-control transcript normalization. Invalid, unsupported, duplicate-ID, or excess definitions remain hidden in reading mode and produce an unavailable-check message. Ordinary code remains visible. The editable native document is unchanged.

## Attempts and reviews

Drafts and outcomes are stored outside the agent-editable workspace, scoped by course, page, question ID, and definition fingerprint. A revised question starts a new attempt while retaining earlier history. One authoritative store per page owns active review tasks across navigation; deletion cancels and invalidates it before removing storage.

Each submission is saved before dispatch with its own ID. Review uses a fresh session with no editing tools. The accepted response is one JSON object, optionally enclosed in a `learnfold-review` fence:

```json
{"version":1,"submission_id":"exact-submission-id","assessment_id":"explain-pumps","outcome":"needs_review","feedback":"Connect the pump's energy supply to ATP.","needs_discussion":true,"opening_question":"Where does the pump get its energy?"}
```

Outcomes are `understood` or `needs_review`. A requested discussion requires a nonempty opening question. Responses with incorrect IDs or invalid fields cannot update an attempt. Choice outcomes remain authoritative from the authored key even if an AI disagrees. If AI review fails, choices can use their local result; free-text answers remain saved and retryable without a guessed grade.

Isolated review supports Hosted, Apple On-Device/PCC, and Codex. Hermes currently reports that isolated exercise review is unavailable; it does not silently switch providers.

## AI-first page discussions

All exercise follow-ups reuse the page's linked discussion, separate from course and passage threads. The opening control instruction is frozen per attempt and tagged for hidden transcript projection; the learner sees the tutor's first question. Provider acceptance produces a receipt scoped to that discussion and instruction hash. Queueing alone does not mark it sent. Reopening preserves the first question, while replacing a missing thread can initialize the replacement once.

Hidden pending controls survive relaunch without entering the learner's composer. Existing human drafts remain intact. Ordinary chat completion does not count as a graded exercise result.
