# Live page editing comparison

Compares Learnfold's current agent tools with an experimental editable Markdown draft and apply workflow. Both save through the actual `NativeEditorMCPService` and `NotionEnhancedMarkdownCodec` from the local checkout, using disposable SQLite databases.

## Run

An existing `OPENCODE_API_KEY` must be present in the environment. The runner does not read, print, or save secret files. It sends only synthetic lesson content and tool definitions to OpenCode.

```sh
swift build --package-path tools/page-edit-benchmark --product PageEditBridge
python3 tools/page-edit-benchmark/self_test.py
python3 tools/page-edit-benchmark/run.py \
  --output artifacts/page-edit-benchmark/my-run \
  --repetitions 3
```

The output directory must not already exist. `--seed-only` creates fixtures without API calls. `--fixture` limits execution to one scenario. A provider failure stops the run to avoid repeatedly consuming requests on a broken configuration. It is retained as a failure in the artifacts.

## Design

- Three scenarios, two methods, three repetitions per pair: 18 independent LLM agent sessions.
- Same model as the current hosted agent, `gpt-5.6-luna`, through `https://opencode.ai/zen/go/v1/responses`.
- Same starting native database, page ID, revision, request, and shared preservation instructions in each pair. Each trial gets a SQLite backup of the seed.
- Fresh session per trial, provider defaults, no reasoning-effort override, full tool history replay, and `store: false`.
- No simultaneous trial requests. Method order alternates to reduce time/order effects. Timing and cache reuse still vary and are reported, not treated as controlled constants.
- The current method receives the actual fetch/update schemas exported from the Swift catalog. It may use targeted or whole-page replacement. The prompt prefers targeted edits as Learnfold currently does.
- The draft method receives `open_page`, `read_file`, `edit_file`, `write_file`, and `apply_page`. These operate on a real local `lesson.md`, bound to an app-owned captured revision. Only apply saves to the native page.
- Both methods can batch multiple exact replacements in one tool call. Draft batches validate all replacements before writing the file, so an invalid later replacement does not partially edit the draft.
- Draft application uses native `replace_content`; native identity reconciliation and opaque-block recovery run on the real engine.
- Both methods must recover from the same injected concurrent learner edit in scenario three, inserted immediately before their first attempted native commit.
- Only the relevant content tools are exposed. Creation, hierarchy changes, properties, trash, background tasks, network tools, and unrelated files are outside the test.

Scenarios:

1. **Precise correction.** Two examples contain the same rate sentence. Update one rate and calculation while leaving the other example, learner note, introduction, and practice unchanged.
2. **Larger rewrite with native blocks.** Simplify an introduction and add two worked HTTP caching examples. Preserve a real executable visualization block, an opaque native plugin block, and unrelated sections.
3. **Concurrent learner edit.** Change two passages, then recover from a real native revision conflict while preserving a newly inserted learner note.

## Evidence and scoring

Each trial saves its request payloads, provider responses and usage, tool arguments/results, starting and final Markdown, native block documents, and SQLite database. Credentials and authorization headers are never written. `manifest.json` records fixture inputs, model, endpoint, and harness hash. `summary.json` contains all completed trial summaries.

Automated checks cover requested text changes, unrelated text preservation, page identity, course metadata, exact visualization/plugin block preservation including stable IDs, and successful conflict recovery. Those checks do not prove writing quality. Read final lesson prose and tool traces before drawing conclusions about educational quality or tool strategy.

Metrics include total elapsed time, individual API latency, number of model requests, tool calls, tool errors, successful native commits, input/output tokens, cached input tokens, and reasoning token counts when the provider reports them. Total input usage counts repeated history; it is not the unique prompt size. A deliberately injected conflict is an expected tool error, not itself a task failure.

`self_test.py` performs six deterministic golden-edit checks without model calls. These validate harness wiring and graders and are excluded from LLM results.

An initial pilot used one replacement per draft edit call. Its artifacts are retained separately, including a copy of that runner. The final comparison gives the draft editor batched replacements to avoid attributing differences in batching capability to the file workflow.

## Limits

This is a host-side native engine evaluation. It does not instantiate the iOS `CourseDocumentRepository`, approval UI, autosave journal, cloud sync, or a phone. The fixtures assume an approved course. The draft adapter is a benchmark prototype, not a shipped Learnfold feature.

The draft file tools provide ordinary read, exact text edit, and complete file write operations. They are not a full coding agent's shell, filesystem search, or unified-diff patch implementation. Results apply to this specific prototype and tool set.

Three repetitions per scenario with one model are a focused comparison, not statistical proof across providers or long documents. Request latency, provider routing, output variation, and prompt caching can affect results. No cost in dollars is inferred without an applicable billing schedule.
