import { LEGACY_COURSE_AGENT_PROMPT, QUESTION_CHOICE_CAPABILITY, QUESTION_FENCE } from "../src/course-prompt"
import { generateText, jsonSchema, tool } from "ai"
import { getAgentByName } from "agents"
import type { TurnContext } from "@cloudflare/think"
import { SELF, env, runInDurableObject } from "cloudflare:test"
import { describe, expect, it } from "vitest"

import { DEFAULT_MODEL, OPENCODE_BASE_URL, createHostedModel } from "../src/provider"
import { authorizeGuestRoute, enforceGuestTurnLimit, mintGuestToken, verifyGuestToken } from "../src/guest"

describe("hosted agent worker", () => {
  it("issues session-bound guest tokens without a login or provider key", async () => {
    const session = crypto.randomUUID()
    const response = await SELF.fetch(`https://agent.test/guest-session?sessionId=${session}`, {
      method: "POST",
      headers: { authorization: `Guest ${"a".repeat(64)}` },
    })
    expect(response.status).toBe(200)
    expect(response.headers.get("cache-control")).toBe("no-store")
    const { accessToken } = await response.json<{ accessToken: string }>()
    expect(await verifyGuestToken(accessToken, "test-access-token", session)).toMatch(/^[0-9a-f]{64}$/)
    expect(await verifyGuestToken(accessToken, "test-access-token", crypto.randomUUID())).toBeNull()
    expect((await SELF.fetch("https://agent.test/health", {
      headers: { authorization: `Bearer ${accessToken}` },
    })).status).toBe(401)
  })

  it("rejects malformed credentials, forged tokens, and expired tokens", async () => {
    expect((await SELF.fetch("https://agent.test/guest-session?sessionId=invalid", { method: "POST" })).status).toBe(400)
    const session = crypto.randomUUID()
    const token = await mintGuestToken("test-access-token", "a".repeat(64), session, 1000)
    expect(await verifyGuestToken(token, "test-access-token", session, 3_601_000)).toBeNull()
    expect(await verifyGuestToken(token, "wrong-key", session, 1000)).toBeNull()
    expect(await verifyGuestToken(token.replace("a".repeat(64), "b".repeat(64)), "test-access-token", session, 1000)).toBeNull()
  })

  it("isolates guest conversations and blocks non-chat endpoints", async () => {
    const session = crypto.randomUUID()
    async function route(subject: string, suffix = "") {
      const token = await mintGuestToken("test-access-token", subject, session)
      return authorizeGuestRoute(new Request(`https://agent.test/agents/hosted-course-agent/${session}${suffix}`, {
        headers: { authorization: `Bearer ${token}`, upgrade: "websocket" },
      }), "test-access-token")
    }
    const first = await route("a".repeat(64))
    const second = await route("b".repeat(64))
    expect(first?.url).toContain(`guest-${"a".repeat(64)}-${session}`)
    expect(second?.url).not.toBe(first?.url)
    expect(await route("a".repeat(64), "/messages")).toBeNull()
  })

  it("opens the real Think chat protocol with a guest token", async () => {
    const session = crypto.randomUUID()
    const token = await mintGuestToken("test-access-token", "e".repeat(64), session)
    const response = await SELF.fetch(`https://agent.test/agents/hosted-course-agent/${session}`, {
      headers: { authorization: `Bearer ${token}`, upgrade: "websocket" },
    })
    expect(response.status).toBe(101)
    const socket = response.webSocket!
    socket.accept()
    const initial = await new Promise<unknown>((resolve) => {
      socket.addEventListener("message", (event) => {
        const data = JSON.parse(event.data as string)
        if (data.type === "cf_agent_chat_messages") resolve(data.messages)
      })
    })
    expect(initial).toEqual([])
    socket.close(1000)
  })

  it("enforces durable per-guest turn limits across sessions", async () => {
    const subject = "c".repeat(64)
    const budget = env.GuestUsage.getByName(`turns:${subject}`)
    for (let index = 0; index < 59; index++) expect(await budget.consume(60)).toBe(true)
    await enforceGuestTurnLimit(`guest-${subject}-${crypto.randomUUID()}`, env)
    await expect(enforceGuestTurnLimit(`guest-${subject}-${crypto.randomUUID()}`, env)).rejects.toThrow("today's Hosted usage limit")
    await expect(enforceGuestTurnLimit(crypto.randomUUID(), env)).resolves.toBeUndefined()
  })

  it("limits guest token issuance by IP", async () => {
    const ip = "192.0.2.18"
    const { hashIdentity } = await import("../src/guest")
    const budget = env.GuestUsage.getByName(`bootstrap:${await hashIdentity(ip)}`)
    for (let index = 0; index < 120; index++) await budget.consume(120)
    const response = await SELF.fetch(`https://agent.test/guest-session?sessionId=${crypto.randomUUID()}`, {
      method: "POST", headers: { authorization: `Guest ${"d".repeat(64)}`, "cf-connecting-ip": ip },
    })
    expect(response.status).toBe(429)
  })

  it("protects the health and agent routes", async () => {
    const anonymous = await SELF.fetch("https://agent.test/health")
    expect(anonymous.status).toBe(401)

    const health = await SELF.fetch("https://agent.test/health", {
      headers: { authorization: "Bearer test-access-token" },
    })
    expect(health.status).toBe(200)
    expect(await health.json()).toMatchObject({
      ok: true,
      runtime: "cloudflare-think",
      model: "muse-spark-1.3-contributor",
      capabilities: ["durable-session", "stream-resume", "auto-compaction", "client-tools"],
    })

    const missing = await SELF.fetch("https://agent.test/not-an-agent", {
      headers: { authorization: "Bearer test-access-token" },
    })
    expect(missing.status).toBe(404)
  })

  it("uses Responses with full transcript replay and no provider storage", async () => {
    let sent: Record<string, unknown> = {}
    let sentHeaders = new Headers()
    let url = ""
    const transport: typeof fetch = async (_input, init) => {
      url = String(_input)
      sent = JSON.parse(String(init?.body))
      sentHeaders = new Headers(init?.headers)
      return Response.json({ id: "resp_test", model: DEFAULT_MODEL, created_at: 1,
        output: [{ type: "message", id: "msg_test", role: "assistant", content: [
          { type: "output_text", text: "ok", annotations: [] },
        ] }], usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } })
    }
    const result = await generateText({
      model: createHostedModel("test-key", transport, "stable-learnfold-session"),
      prompt: "Question",
    })
    expect(result.text).toBe("ok")
    expect(url).toBe(`${OPENCODE_BASE_URL}/responses`)
    expect(sent.store).toBe(false)
    expect(sent).not.toHaveProperty("max_output_tokens")
    expect(sent).not.toHaveProperty("reasoning")
    expect(sent).not.toHaveProperty("messages")
    expect(sent.input).toBeDefined()
    expect(sent.model).toBe(DEFAULT_MODEL)
    expect(sentHeaders.get("x-opencode-session")).toBe("stable-learnfold-session")
    expect(sentHeaders.get("user-agent")).toBe("learnfold-hosted-agent/1.0")
  })

  it("uses the OpenCode Zen Go Responses adapter", () => {
    const model = createHostedModel("not-a-real-key")
    expect(OPENCODE_BASE_URL).toBe("https://opencode.ai/zen/go/v1")
    expect(DEFAULT_MODEL).toBe("muse-spark-1.3-contributor")
    expect(model.modelId).toBe("muse-spark-1.3-contributor")
    expect(model.provider).toContain("opencode-zen-go")
  })

  it("replays legacy text history and client tool results through Responses without item references", async () => {
    const requests: Record<string, unknown>[] = []
    const model = createHostedModel("test-key", async (_input, init) => {
      requests.push(JSON.parse(String(init?.body)))
      return Response.json({ id: `resp_${requests.length}`, model: DEFAULT_MODEL, created_at: 1,
        output: requests.length === 1
          ? [{ type: "function_call", id: "fc_test", call_id: "call_test", name: "native-editor-fetch", arguments: '{"id":"lesson"}' }]
          : [{ type: "message", id: "msg_test", role: "assistant", content: [
              { type: "output_text", text: "The lesson says hello.", annotations: [] },
            ] }],
        usage: { input_tokens: 10, output_tokens: 10, total_tokens: 20 } })
    })
    const tools = { "native-editor-fetch": tool({
      inputSchema: jsonSchema<{ id: string }>({ type: "object", properties: { id: { type: "string" } }, required: ["id"] }),
    }) }
    const messages = [
      { role: "user" as const, content: "An older DeepSeek question" },
      { role: "assistant" as const, content: "An older DeepSeek answer" },
      { role: "user" as const, content: "Fetch my lesson" },
    ]
    const first = await generateText({ model, messages, tools })
    expect(first.toolCalls[0]).toMatchObject({ toolCallId: "call_test", toolName: "native-editor-fetch", input: { id: "lesson" } })
    const second = await generateText({ model, tools, messages: [
      ...messages, ...first.response.messages,
      { role: "tool", content: [{ type: "tool-result", toolCallId: "call_test", toolName: "native-editor-fetch",
        output: { type: "json", value: { content: "hello" } } }] },
    ] })
    expect(second.text).toBe("The lesson says hello.")
    expect(requests[1].store).toBe(false)
    expect(requests[1]).not.toHaveProperty("max_output_tokens")
    expect(requests[1].input).toEqual(expect.arrayContaining([
      expect.objectContaining({ type: "function_call", call_id: "call_test" }),
      expect.objectContaining({ type: "function_call_output", call_id: "call_test", output: '{"content":"hello"}' }),
    ]))
    expect(JSON.stringify(requests[1].input)).not.toContain("item_reference")
    expect(JSON.stringify(requests[1].input)).toContain("An older DeepSeek answer")
  })
})


describe("Hosted course workspace continuity", () => {
  it("gates choice instructions by client support across turns and body-less continuations", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent, state) => {
      expect(agent.getSystemPrompt()).toBe(LEGACY_COURSE_AGENT_PROMPT)
      const legacy = await agent.beforeTurn(context({ workspaceId: "course-a" }))
      expect(legacy.instructions).toContain("Ask concise questions")
      expect(legacy.instructions).not.toContain(QUESTION_FENCE)

      const supported = await agent.beforeTurn(context({
        workspaceId: "course-a", clientCapabilities: [QUESTION_CHOICE_CAPABILITY],
      }))
      expect(supported.instructions).toContain(QUESTION_FENCE)
      expect(supported.instructions).toContain("works in New Course and course-building chat")
      expect(await state.storage.get("learnfold.questionChoices")).toBe(true)
    })
    await runInDurableObject(stub, async (agent) => {
      const continuation = await agent.beforeTurn(context(undefined, true))
      expect(continuation.instructions).toContain(QUESTION_FENCE)

      const downgraded = await agent.beforeTurn(context({ workspaceId: "course-a" }))
      expect(downgraded.instructions).toContain("Ask concise questions")
      expect(downgraded.instructions).not.toContain(QUESTION_FENCE)
      expect((await agent.beforeTurn(context(undefined, true))).instructions).not.toContain(QUESTION_FENCE)
    })
  })


  function context(body?: Record<string, unknown>, continuation = false): TurnContext {
    return { body, continuation, messages: [], tools: {}, system: "Course agent", model: createHostedModel("test-key") }
  }

  function generationContext(text: string, body?: Record<string, unknown>, continuation = false): TurnContext {
    return {
      ...context(body, continuation),
      messages: [{ role: "user", content: [{ type: "text", text }] }],
      tools: Object.fromEntries([
        "present_course_plan", "native-editor-fetch", "native-editor-update-page",
        "native-editor-get-async-task", "native-editor-create-pages", "native-editor-move-pages", "course_bash",
      ].map((name) => [name, tool({
        description: name,
        inputSchema: jsonSchema({ type: "object", properties: {} }),
      })])),
    }
  }

  it.each(["approve_course_plan", "generate_course_node"])(
    "restricts tagged %s turns to exact-page fetch and atomic lesson updates", async (purpose) => {
      const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
      const prompt = `<learnfold_internal_course_instruction version="1">\npurpose: ${purpose}\nGenerate only page gene-expression.\n</learnfold_internal_course_instruction>`
      await runInDurableObject(stub, async (agent) => {
        const result = await agent.beforeTurn(generationContext(prompt, { workspaceId: "course-a" }))
        expect(result.activeTools).toEqual(["native-editor-fetch", "native-editor-update-page", "native-editor-get-async-task"])
        expect(result.instructions).toContain("exact target immediately before native-editor-update-page")
        expect(result.instructions).toContain("properties.generation_status = generated in the same native-editor-update-page call")
        expect(result.instructions).toContain("never update the root, context pages, ancestors, siblings, or later lessons")
        expect(result.instructions).toContain("a chat-only answer does not complete generation")
        expect(result.instructions).toContain("poll that handle with native-editor-get-async-task until it reports terminal success")
      })
    },
  )

  it("preserves generation restrictions through a body-less continuation with compacted messages", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    const prompt = '<learnfold_internal_course_instruction version="1">\npurpose: generate_course_node\nGenerate only page gene-expression.\n</learnfold_internal_course_instruction>'
    await runInDurableObject(stub, async (agent, state) => {
      await agent.beforeTurn(generationContext(prompt, { workspaceId: "course-a" }))
      expect(await state.storage.get("learnfold.generationTurn")).toBe("nextLesson")
    })
    await runInDurableObject(stub, async (agent) => {
      const continuation = generationContext("", undefined, true)
      continuation.messages = []
      const result = await agent.beforeTurn(continuation)
      expect(result.activeTools).toEqual(["native-editor-fetch", "native-editor-update-page", "native-editor-get-async-task"])
      expect(result.instructions).toContain("single-page course generation turn")
      expect(result.instructions).toContain("workspace_id: course-a")
    })
  })

  it("preserves generation policy when the same admitted request retries after reactive compaction", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    const requestID = crypto.randomUUID()
    const prompt = '<learnfold_internal_course_instruction version="1">\npurpose: generate_course_node\nGenerate only page gene-expression.\n</learnfold_internal_course_instruction>'
    await runInDurableObject(stub, async (agent, state) => {
      agent.observability.emit({ type: "chat:turn:start", payload: { requestId: requestID } })
      await agent.beforeTurn(generationContext(prompt, { workspaceId: "course-a" }))
      expect(await state.storage.get("learnfold.generationRequestId")).toBe(requestID)
      // Think retries inside the same admitted request with continuation:false.
      const retry = generationContext("Generate the requested lesson.", { workspaceId: "course-a" })
      const result = await agent.beforeTurn(retry)
      expect(result.activeTools).toEqual(["native-editor-fetch", "native-editor-update-page", "native-editor-get-async-task"])
      expect(result.instructions).toContain("single-page course generation turn")
      expect(await state.storage.get("learnfold.generationTurn")).toBe("nextLesson")
      agent.observability.emit({ type: "chat:turn:finish", payload: { requestId: requestID } })

      // A later learner message is a different admitted request and releases it.
      const nextRequestID = crypto.randomUUID()
      agent.observability.emit({ type: "chat:turn:start", payload: { requestId: nextRequestID } })
      const question = await agent.beforeTurn(generationContext("Explain ATP.", { workspaceId: "course-a" }))
      expect(question.activeTools).toContain("native-editor-create-pages")
      expect(question.instructions).not.toContain("single-page course generation turn")
      expect(await state.storage.get("learnfold.generationRequestId")).toBeUndefined()
      agent.observability.emit({ type: "chat:turn:finish", payload: { requestId: nextRequestID } })
    })
  })

  it("clears generation restrictions on the next learner message and its continuations", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    const prompt = '<learnfold_internal_course_instruction version="1">\npurpose: generate_course_node\nGenerate only page gene-expression.\n</learnfold_internal_course_instruction>'
    await runInDurableObject(stub, async (agent, state) => {
      await agent.beforeTurn(generationContext(prompt, { workspaceId: "course-a" }))
      const question = generationContext("Explain the previous lesson.", { workspaceId: "course-a" })
      const result = await agent.beforeTurn(question)
      expect(result.activeTools).toContain("present_course_plan")
      expect(result.activeTools).toContain("native-editor-create-pages")
      expect(result.instructions).not.toContain("single-page course generation turn")
      expect(await state.storage.get("learnfold.generationTurn")).toBeUndefined()
      const continuation = await agent.beforeTurn({ ...question, body: undefined, continuation: true })
      expect(continuation.activeTools).toEqual(result.activeTools)
      expect(continuation.instructions).not.toContain("single-page course generation turn")
    })
  })

  it("preserves policy for recovery of the same durable learner message under a new request ID", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    const prompt = '<learnfold_internal_course_instruction version="1">\npurpose: generate_course_node\nGenerate only page gene-expression.\n</learnfold_internal_course_instruction>'
    const userMessageID = crypto.randomUUID()
    await runInDurableObject(stub, async (agent, state) => {
      await agent.addMessages([{ id: userMessageID, role: "user", parts: [{ type: "text", text: prompt }] }], { broadcast: false })
      const requestID = crypto.randomUUID()
      agent.observability.emit({ type: "chat:turn:start", payload: { requestId: requestID } })
      await agent.beforeTurn(generationContext(prompt, { workspaceId: "course-a" }))
      expect(await state.storage.get("learnfold.generationUserMessageId")).toBe(userMessageID)
      agent.observability.emit({ type: "chat:turn:finish", payload: { requestId: requestID } })

      const recoveryRequestID = crypto.randomUUID()
      agent.observability.emit({ type: "chat:turn:start", payload: { requestId: recoveryRequestID } })
      const recovery = await agent.beforeTurn(generationContext("Resume the requested lesson.", { workspaceId: "course-a" }))
      expect(recovery.activeTools).not.toContain("native-editor-create-pages")
      expect(recovery.instructions).toContain("single-page course generation turn")
      agent.observability.emit({ type: "chat:turn:finish", payload: { requestId: recoveryRequestID } })

      await agent.addMessages([{ id: crypto.randomUUID(), role: "user", parts: [{ type: "text", text: "Explain ATP." }] }], { broadcast: false })
      const nextRequestID = crypto.randomUUID()
      agent.observability.emit({ type: "chat:turn:start", payload: { requestId: nextRequestID } })
      const question = await agent.beforeTurn(generationContext("Explain ATP.", { workspaceId: "course-a" }))
      expect(question.instructions).not.toContain("single-page course generation turn")
      expect(await state.storage.get("learnfold.generationUserMessageId")).toBeUndefined()
      agent.observability.emit({ type: "chat:turn:finish", payload: { requestId: nextRequestID } })
    })
  })

  it("retains legacy approval support and allows a conflict refresh for supplied revisions", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent) => {
      const result = await agent.beforeTurn(generationContext(
        "I approve course plan plan-1 revision 1. Call native-editor-update-page directly.",
        { workspaceId: "course-a" },
      ))
      expect(result.activeTools).toEqual(["native-editor-fetch", "native-editor-update-page", "native-editor-get-async-task"])
      expect(result.instructions).toContain("supplied page ID and expected revision")
      expect(result.instructions).toContain("Do not fetch unless the update reports a revision conflict")
    })
  })

  it("does not restrict normal questions that quote a generation instruction", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent) => {
      const result = await agent.beforeTurn(generationContext(
        'What does this mean: <learnfold_internal_course_instruction version="1">\npurpose: generate_course_node\nGenerate a page.\n</learnfold_internal_course_instruction>',
        { workspaceId: "course-a" },
      ))
      expect(result.activeTools).toContain("present_course_plan")
      expect(result.instructions).not.toContain("single-page course generation turn")
    })
  })

  it.each(["guest", "test"])("does not cap output tokens for %s turns or continuations", async (prefix) => {
    const subject = crypto.randomUUID().replaceAll("-", "").repeat(2)
    const name = `${prefix}-${subject}-${crypto.randomUUID()}`
    const stub = await getAgentByName(env.HostedCourseAgent, name)
    await runInDurableObject(stub, async (agent) => {
      expect((await agent.beforeTurn(context({ workspaceId: "course-a" }))).maxOutputTokens).toBeUndefined()
      expect((await agent.beforeTurn(context(undefined, true))).maxOutputTokens).toBeUndefined()
    })
  })

  it("switches passage and page discussions to the existing-course prompt, durably", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent) => {
      const discussion = generationContext("Explain this passage.", { workspaceId: "course-a" })
      delete (discussion.tools as Record<string, unknown>)["present_course_plan"]
      const result = await agent.beforeTurn(discussion)
      expect(result.instructions).toContain("never creates or replans a course")
      expect(result.activeTools).not.toContain("present_course_plan")
      expect(result.activeTools).toContain("native-editor-create-pages")
      const continuation = await agent.beforeTurn(context(undefined, true))
      expect(continuation.instructions).toContain("never creates or replans a course")
    })
    const course = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    await runInDurableObject(course, async (agent) => {
      const result = await agent.beforeTurn(generationContext("Build a course.", { workspaceId: "course-a" }))
      expect(result.instructions).not.toContain("never creates or replans a course")
      expect(result.activeTools).toContain("present_course_plan")
    })
  })

  it("keeps the workspace for body-less tool continuations in durable storage", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent, state) => {
      await agent.beforeTurn(context({ workspaceId: "course-a" }))
      expect(await state.storage.get("learnfold.workspaceId")).toBe("course-a")
    })
    await runInDurableObject(stub, async (agent) => {
      const result = await agent.beforeTurn(context(undefined, true))
      expect(result.instructions).toContain("Current Learnfold workspace_id: course-a")
    })
  })

  it("leaves Muse reasoning at its default for passage questions and continuations", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent) => {
      const focused = context({ workspaceId: "course-a" })
      focused.messages = [{ role: "user", content: 'I selected the following passage from the native course page `Lesson` while studying.\n\n<selected_course_passage page_id="lesson" title="Lesson">\nA passage\n</selected_course_passage>\n\nMy question: Explain this.' }]
      expect((await agent.beforeTurn(focused)).providerOptions).toBeUndefined()
      const continuation = { ...focused, body: undefined, continuation: true }
      expect((await agent.beforeTurn(continuation)).providerOptions).toBeUndefined()
      for (const text of ["Build a deep course", "I approve course plan plan-1 revision 1", "Explain what selected_course_passage means"]) {
        const planning = { ...focused, messages: [{ role: "user" as const, content: text }] }
        expect((await agent.beforeTurn(planning)).providerOptions).toBeUndefined()
      }
    })
  })

  it("rejects missing or malformed workspace IDs on new requests", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent) => {
      await expect(agent.beforeTurn(context(undefined, true))).rejects.toThrow("workspaceId")
      await agent.beforeTurn(context({ workspaceId: "course-a" }))
      await expect(agent.beforeTurn(context())).rejects.toThrow("workspaceId")
      await expect(agent.beforeTurn(context({ workspaceId: "../bad" }, true))).rejects.toThrow("workspaceId")
    })
  })

  it("does not allow another course to rebind an existing conversation", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `test-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent) => {
      await agent.beforeTurn(context({ workspaceId: "course-a" }))
      await expect(agent.beforeTurn(context({ workspaceId: "course-b" }))).rejects.toThrow("different course")
      expect((await agent.beforeTurn(context(undefined, true))).instructions).toContain("course-a")
    })
  })
})
