import { SELF, env, runInDurableObject } from "cloudflare:test"
import { getAgentByName } from "agents"
import { describe, expect, it } from "vitest"
import { hashIdentity, mintGuestToken } from "../src/guest"
import { HostedTurnOwnership, awaitsClientTools, matchesPendingClientTool } from "../src/turn-ownership"
import { answerEvents, completed, created, encode } from "./responses-fixtures"

describe("Hosted cross-device continuation", () => {
  it("runs a real Think tool continuation only on its origin while the other device reads history", async () => {
    const name = `real-continuation-${crypto.randomUUID()}`
    const stub = await getAgentByName(env.HostedCourseAgent, name)
    let providerCalls = 0
    await runInDurableObject(stub, (agent) => {
      agent.chatRecovery = { maxAttempts: 0, terminalMessage: "Stopped" }
      const getModel = agent.getModel.bind(agent)
      agent.getModel = () => {
        const original = globalThis.fetch
        globalThis.fetch = async () => {
          providerCalls += 1
          const item = { type: "function_call", id: "fc_test", call_id: "native-tool-1", name: "native-editor-fetch", arguments: "{}" }
          const events = providerCalls === 1 ? [
            created,
            { type: "response.output_item.added", output_index: 0, item: { ...item, arguments: "" } },
            { type: "response.function_call_arguments.delta", item_id: item.id, output_index: 0, delta: "{}" },
            { type: "response.output_item.done", output_index: 0, item: { ...item, status: "completed" } },
            completed,
          ] : [created, ...answerEvents("Saved answer after native tool")]
          return new Response(new ReadableStream<Uint8Array>({ start(controller) {
            for (const event of events) controller.enqueue(encode(event))
            controller.close()
          } }), { headers: { "content-type": "text/event-stream" } })
        }
        try { return getModel() } finally { globalThis.fetch = original }
      }
    })
    async function connect(originID: string) {
      const response = await SELF.fetch(`https://agent.test/agents/hosted-course-agent/${name}`, {
        headers: { authorization: "Bearer test-access-token", upgrade: "websocket", "x-learnfold-origin-id": originID },
      })
      expect(response.status).toBe(101)
      const socket = response.webSocket!
      socket.accept()
      return socket
    }
    const phone = await connect(crypto.randomUUID())
    const phoneFrames: Record<string, unknown>[] = []
    const toolReady = new Promise<void>((resolve, reject) => {
      const deadline = setTimeout(() => reject(Error(`Origin did not receive its native tool: ${JSON.stringify(phoneFrames)}`)), 3_000)
      let submitted = false
      phone.addEventListener("message", (event) => {
        const frame = JSON.parse(event.data as string)
        phoneFrames.push(frame)
        if (frame.type === "cf_agent_chat_messages" && !submitted) {
          submitted = true
          phone.send(JSON.stringify({ type: "cf_agent_use_chat_request", id: "phone-request", init: {
            method: "POST", body: JSON.stringify({ workspaceId: "shared-course", clientTools: [{
              name: "native-editor-fetch", description: "Read the native lesson", parameters: { type: "object", properties: {} },
            }], messages: [{ id: "learner-request", role: "user", parts: [{ type: "text", text: "Read my lesson before answering" }] }] }),
          } }))
        }
        if (frame.type === "cf_agent_use_chat_response" && frame.body && !frame.error) {
          try {
            if (JSON.parse(frame.body).type === "tool-input-available") { clearTimeout(deadline); resolve() }
          } catch { /* A terminal error is checked by the assertions below. */ }
        }
      })
    })
    await toolReady
    await runInDurableObject(stub, async (_agent, state) => {
      expect((await new HostedTurnOwnership(state.storage).current())?.originID).toBeDefined()
    })
    const mac = await connect(crypto.randomUUID())
    const macFrames: Record<string, unknown>[] = []
    await new Promise<void>((resolve, reject) => {
      const deadline = setTimeout(() => reject(Error("Second-device request did not fail safely")), 3_000)
      let submitted = false
      mac.addEventListener("message", (event) => {
        const frame = JSON.parse(event.data as string)
        macFrames.push(frame)
        if (frame.type === "cf_agent_chat_messages" && !submitted) {
          submitted = true
          mac.send(JSON.stringify({ type: "cf_agent_tool_result", toolCallId: "native-tool-1", toolName: "native-editor-fetch", output: { from: "wrong-device" }, state: "output-available", autoContinue: true }))
          mac.send(JSON.stringify({ type: "cf_agent_use_chat_request", id: "mac-request", init: { method: "POST", body: JSON.stringify({ workspaceId: "shared-course", messages: [{ id: "duplicate", role: "user", parts: [{ type: "text", text: "Generate again" }] }] }) } }))
        }
        if (frame.id === "mac-request" && frame.done) { clearTimeout(deadline); resolve() }
      })
    })
    expect(macFrames.find((frame) => frame.type === "learnfold_hosted_session_status")).toMatchObject({ active: true, originatingDevice: false })
    expect(macFrames.find((frame) => frame.id === "mac-request")).toMatchObject({ error: true, done: true })
    await runInDurableObject(stub, (agent) => {
      expect(agent.messages.some((message) => message.id === "duplicate")).toBe(false)
      expect(JSON.stringify(agent.messages)).not.toContain("wrong-device")
    })
    expect(providerCalls).toBe(1)
    await new Promise<void>((resolve, reject) => {
      const deadline = setTimeout(() => reject(Error("Origin's tool continuation did not finish")), 3_000)
      phone.addEventListener("message", (event) => {
        const frame = JSON.parse(event.data as string)
        if (frame.continuation && frame.done) { clearTimeout(deadline); resolve() }
      })
      phone.send(JSON.stringify({ type: "cf_agent_tool_result", toolCallId: "native-tool-1", toolName: "native-editor-fetch", output: { revision: 4, content: "Local lesson" }, state: "output-available", autoContinue: true }))
    })
    await runInDurableObject(stub, async (agent, state) => {
      const ownership = new HostedTurnOwnership(state.storage)
      expect(await ownership.current()).toBeUndefined()
      expect(await ownership.lastOutcome()).toBe("completed")
      expect(JSON.stringify(agent.messages)).toContain("Saved answer after native tool")
      expect(JSON.stringify(agent.messages)).toContain("output-available")
    })
    expect(providerCalls).toBe(2)
    phone.close(1000)
    mac.close(1000)
  })

  it("restores the same durable history with a transferred identity and keeps other identities isolated", async () => {
    const session = crypto.randomUUID()
    const subject = await hashIdentity("a".repeat(64))
    const stub = await getAgentByName(env.HostedCourseAgent, `guest-${subject}-${session}`)
    const transcript = [
      { id: "question", role: "user" as const, parts: [{ type: "text" as const, text: "Explain this lesson" }] },
      { id: "answer", role: "assistant" as const, parts: [
        { type: "text" as const, text: "Your saved answer" },
        { type: "dynamic-tool" as const, toolName: "native-editor-fetch", toolCallId: "saved-tool", state: "output-available" as const, input: {}, output: { revision: 4 } },
      ] },
    ]
    await runInDurableObject(stub, async (agent) => { await agent.addMessages(transcript, { broadcast: false }) })

    async function open(owner: string) {
      const token = await mintGuestToken("test-access-token", owner, session)
      const response = await SELF.fetch(`https://agent.test/agents/hosted-course-agent/${session}`, {
        headers: { authorization: `Bearer ${token}`, upgrade: "websocket", "x-learnfold-origin-id": crypto.randomUUID() },
      })
      expect(response.status).toBe(101)
      const socket = response.webSocket!
      socket.accept()
      const history = await new Promise<unknown>((resolve, reject) => {
        const deadline = setTimeout(() => reject(Error("No saved Hosted history")), 3_000)
        socket.addEventListener("message", (event) => {
          const frame = JSON.parse(event.data as string)
          if (frame.type === "cf_agent_chat_messages") { clearTimeout(deadline); resolve(frame.messages) }
        })
      })
      socket.close(1000)
      return history
    }
    expect(await open(subject)).toEqual(transcript)
    expect(await open(subject)).toEqual(transcript)
    expect(await open(await hashIdentity("b".repeat(64)))).toEqual([])
  })

  it("admits only one device and preserves that owner through native tool pauses", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `ownership-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (_agent, state) => {
      const ownership = new HostedTurnOwnership(state.storage)
      const admitted = await Promise.all([
        ownership.admit("phone", "phone-request"), ownership.admit("mac", "mac-request"),
      ])
      expect(admitted.filter(Boolean)).toHaveLength(1)
      const original = await ownership.current()
      await ownership.stepFinished(true)
      // New helper reads the durable owner, including after a process restart.
      const restored = new HostedTurnOwnership(state.storage)
      expect(await restored.current()).toEqual({ ...original, waitingForTools: true })
      expect(await restored.admit("other-device", "duplicate-request")).toBe(false)
      await restored.stepFinished(false, undefined, "completed")
      expect(await restored.current()).toBeUndefined()
      expect(await restored.lastOutcome()).toBe("completed")
      expect(await restored.admit("other-device", "next-discussion-turn")).toBe(true)
      // A delayed cleanup of the earlier turn cannot release its successor.
      await restored.stepFinished(false, original!.requestID)
      expect((await restored.current())?.requestID).toBe("next-discussion-turn")
    })
  })

  it("rejects competing requests before history and tool context can be changed", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `admission-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent, state) => {
      const ownership = new HostedTurnOwnership(state.storage)
      await ownership.admit("phone", "original-request")
      const messages = [{ id: "original-message", role: "user" as const, parts: [{ type: "text" as const, text: "Generate the approved lesson" }] }]
      await agent.addMessages(messages, { broadcast: false })
      const sent: Record<string, unknown>[] = []
      const otherDevice = {
        id: "mac-connection", state: { learnfoldOriginID: "mac" },
        send: (value: string) => sent.push(JSON.parse(value)),
      } as unknown as Parameters<typeof agent.onMessage>[0]
      await agent.onMessage(otherDevice, JSON.stringify({
        type: "cf_agent_use_chat_request", id: "competing-request",
        init: { method: "POST", body: JSON.stringify({ workspaceId: "wrong-course", messages: [
          { id: "duplicate", role: "user", parts: [{ type: "text", text: "Start again" }] },
        ] }) },
      }))
      expect(sent).toEqual([expect.objectContaining({ id: "competing-request", error: true, done: true })])
      expect(String(sent[0].body)).toContain("original device")
      expect(agent.messages).toEqual(messages)
      expect(await state.storage.get("learnfold.workspaceId")).toBeUndefined()
      expect((await ownership.current())?.requestID).toBe("original-request")
    })
  })

  it("keeps tool results on the originating device and never mistakes a tool pause for completion", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `tools-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent, state) => {
      const ownership = new HostedTurnOwnership(state.storage)
      await ownership.admit("phone", "original-request")
      const message = { id: "pending-assistant", role: "assistant" as const, parts: [
        { type: "dynamic-tool" as const, toolName: "native-editor-update-page", toolCallId: "pending", state: "input-available" as const, input: { page_id: "lesson-a" } },
      ] }
      await agent.addMessages([message], { broadcast: false })
      await agent.onChatResponse({ message, requestId: "original-request", continuation: false, status: "completed" })
      expect((await ownership.current())?.waitingForTools).toBe(true)
      const otherDevice = { id: "mac", state: { learnfoldOriginID: "mac" }, send: () => {} } as unknown as Parameters<typeof agent.onMessage>[0]
      await agent.onMessage(otherDevice, JSON.stringify({ type: "cf_agent_tool_result", toolCallId: "pending", toolName: "native-editor-update-page", state: "output-available", output: { success: true }, autoContinue: true }))
      expect(agent.messages).toEqual([message])
      expect(await ownership.lastOutcome()).toBeUndefined()
      await agent.onChatResponse({ message: { id: "final-answer", role: "assistant", parts: [{ type: "text", text: "Saved the lesson" }] }, requestId: "continuation", continuation: true, status: "completed" })
      expect(await ownership.current()).toBeUndefined()
      expect(await ownership.lastOutcome()).toBe("completed")
    })
  })

  it("treats tool errors as terminal history and unresolved input as active work", () => {
    expect(awaitsClientTools([{ type: "dynamic-tool", state: "input-available" }])).toBe(true)
    expect(awaitsClientTools([{ type: "tool-native-editor-fetch", state: "input-streaming" }])).toBe(true)
    expect(awaitsClientTools([{ type: "tool-native-editor-fetch", state: "output-error" }])).toBe(false)
    expect(awaitsClientTools([{ type: "text", text: "Done" }])).toBe(false)
  })

  it("blocks new requests on a pre-ownership pause and adopts only its exact original tool result", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `legacy-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent, state) => {
      const pending = { id: "legacy-paused", role: "assistant" as const, parts: [{
        type: "dynamic-tool" as const, toolName: "native-editor-fetch", toolCallId: "legacy-call",
        state: "input-available" as const, input: {},
      }] }
      await agent.addMessages([pending], { broadcast: false })
      const sent: Record<string, unknown>[] = []
      const observer = { id: "observer", state: { learnfoldOriginID: "observer" },
        send: (value: string) => sent.push(JSON.parse(value)) } as unknown as Parameters<typeof agent.onMessage>[0]
      await agent.onMessage(observer, JSON.stringify({ type: "cf_agent_tool_result", toolCallId: "wrong-call",
        toolName: "native-editor-fetch", state: "output-available", output: "wrong", autoContinue: false }))
      await agent.onMessage(observer, JSON.stringify({ type: "cf_agent_use_chat_request", id: "duplicate",
        init: { method: "POST", body: JSON.stringify({ workspaceId: "course-a", messages: [] }) } }))
      expect(sent).toEqual([expect.objectContaining({ id: "duplicate", error: true, done: true })])
      expect(await new HostedTurnOwnership(state.storage).current()).toBeUndefined()
      expect(agent.messages).toEqual([pending])
      const origin = { id: "original", state: { learnfoldOriginID: "original" }, send: () => {} } as unknown as Parameters<typeof agent.onMessage>[0]
      await agent.onMessage(origin, JSON.stringify({ type: "cf_agent_tool_result", toolCallId: "legacy-call",
        toolName: "native-editor-fetch", state: "output-available", output: { revision: 4 }, autoContinue: false }))
      expect(await new HostedTurnOwnership(state.storage).current()).toEqual({
        originID: "original", requestID: "legacy-native-legacy-call", waitingForTools: true,
      })
      await expect.poll(() => JSON.stringify(agent.messages)).toContain("output-available")
      expect(JSON.stringify(agent.messages)).toContain('"revision":4')
    })
  })

  it("requires the precise pending tool shape before legacy ownership adoption", () => {
    const pending = [{ type: "dynamic-tool", toolName: "native-editor-fetch", toolCallId: "call", state: "input-available" }]
    const result = { type: "cf_agent_tool_result", toolCallId: "call", toolName: "native-editor-fetch", state: "output-available" }
    expect(matchesPendingClientTool(pending, result)).toBe(true)
    expect(matchesPendingClientTool(pending, { ...result, toolCallId: "other" })).toBe(false)
    expect(matchesPendingClientTool(pending, { ...result, toolName: "native-editor-update-page" })).toBe(false)
    expect(matchesPendingClientTool(pending, { ...result, state: "input-available" })).toBe(false)
    expect(matchesPendingClientTool([{ ...pending[0], state: "output-available" }], result)).toBe(false)
    expect(matchesPendingClientTool(pending, { type: "cf_agent_chat_clear", toolCallId: "call" })).toBe(false)
    expect(matchesPendingClientTool(pending, { type: "cf_agent_tool_approval", toolCallId: "call", approved: true })).toBe(true)
    expect(matchesPendingClientTool(pending, { type: "cf_agent_tool_approval", toolCallId: "call", approved: "true" })).toBe(false)
  })

  it("releases model-phase ownership after the real SDK exhaustion terminal write, never from its early hook", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `exhausted-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent, state) => {
      const owner = new HostedTurnOwnership(state.storage)
      await owner.admit("origin", "model-request")
      await owner.resumeInference("model-request")
      await state.storage.put("cf:chat:recovering", { requestId: "model-request", at: Date.now() })
      state.storage.sql.exec("INSERT INTO cf_ai_chat_stream_metadata (id,request_id,status,created_at) VALUES(?,?,?,?)", "model-stream", "model-request", "streaming", Date.now())
      const exhaust: unknown = Reflect.get(agent, "_exhaustChatRecovery")
      if (typeof exhaust !== "function") throw new Error("Pinned Think exhaustion boundary changed")
      let ownedDuringEarlyHook = false
      await exhaust.call(agent, {
        incidentId: "exhaust-fixture", requestId: "model-request", recoveryRootRequestId: "model-request",
        attempt: 1, maxAttempts: 1, recoveryKind: "continue", status: "exhausted",
        firstSeenAt: Date.now(), lastAttemptAt: Date.now(),
      }, { terminalMessage: "Stopped", onExhausted: async () => {
        ownedDuringEarlyHook = (await owner.current()) !== undefined
      } }, { text: "", parts: [] }, "model-stream", Date.now())
      expect(ownedDuringEarlyHook).toBe(true)
      expect(await owner.current()).toBeDefined()
      expect(await state.storage.get("cf:chat:last-terminal")).toMatchObject({ requestId: "model-request" })
      expect(await state.storage.get("cf:chat:recovering")).toBeUndefined()
      await owner.reconcileTerminalOutcome(() => false, () => false)
      expect(await owner.current()).toBeUndefined()
      expect(await owner.lastOutcome()).toBe("error")
    })
  })

  it("keeps current continuation ownership through streaming and scheduled recovery, then settles its terminal wake", async () => {
    const stub = await getAgentByName(env.HostedCourseAgent, `wake-${crypto.randomUUID()}`)
    await runInDurableObject(stub, async (agent, state) => {
      const owner = new HostedTurnOwnership(state.storage)
      await owner.admit("origin", "initial-request")
      await owner.resumeInference("current-continuation")
      state.storage.sql.exec("INSERT INTO cf_ai_chat_stream_metadata (id,request_id,status,created_at) VALUES(?,?,?,?)", "first-stream", "initial-request", "completed", 1)
      state.storage.sql.exec("INSERT INTO cf_ai_chat_stream_metadata (id,request_id,status,created_at) VALUES(?,?,?,?)", "next-stream", "current-continuation", "streaming", 2)
      await state.storage.put("cf:chat:last-terminal", { requestId: "initial-request", body: "Old terminal" })
      await owner.reconcileTerminalOutcome(() => false, () => false)
      expect(await owner.current()).toBeDefined()
      await state.storage.delete("cf:chat:last-terminal")
      state.storage.sql.exec("UPDATE cf_ai_chat_stream_metadata SET status='completed' WHERE id='next-stream'")
      await state.storage.put("cf:chat:recovering", { requestId: "current-continuation", at: Date.now() })
      await owner.reconcileTerminalOutcome(() => false, () => false)
      expect(await owner.current()).toBeDefined()
      const incident = { incidentId: "wake-fixture", requestId: "current-continuation", recoveryRootRequestId: "current-continuation", status: "scheduled" }
      await state.storage.put("cf:chat-recovery:incident:wake-fixture", incident)
      const dispatch: unknown = Reflect.get(agent, "_dispatchRecoveredThinkTurn")
      if (typeof dispatch !== "function") throw new Error("Pinned Think terminal wake boundary changed")
      await dispatch.call(agent, { incident, options: { continue: true }, requestId: "current-continuation",
        recoveryRootRequestId: "current-continuation", streamStatus: "completed", detail: { retryTargetUserId: null }, recoveryKind: "continue" })
      expect(await state.storage.get("cf:chat:recovering")).toBeUndefined()
      await owner.reconcileTerminalOutcome(() => true, () => false)
      expect(await owner.current()).toBeDefined()
      await owner.reconcileTerminalOutcome(() => false, () => true)
      expect((await owner.current())?.waitingForTools).toBe(true)
      await owner.reconcileTerminalOutcome(() => false, () => false)
      expect(await owner.current()).toBeUndefined()
      expect(await owner.lastOutcome()).toBe("completed")
    })
  })

  it("recovers a persisted interrupted tool pause only after origin reconnect and native page refresh", async () => {
    const name = `interrupted-${crypto.randomUUID()}`
    const originID = crypto.randomUUID()
    const stub = await getAgentByName(env.HostedCourseAgent, name)
    await runInDurableObject(stub, async (agent, state) => {
      await state.storage.put("learnfold.workspaceId", "course-a")
      const owner = new HostedTurnOwnership(state.storage)
      await owner.admit(originID, "original-request")
      await owner.stepFinished(true)
      // Model a process/storage interruption after recovery was claimed but
      // before its history updates and release committed. A new socket must
      // be able to resume that same origin's deterministic recovery.
      expect(await owner.beginRecovery(originID)).toBeDefined()
      expect((await new HostedTurnOwnership(state.storage).current())?.recovering).toBe(true)
      await agent.addMessages([
        { id: "learner", role: "user", parts: [{ type: "text", text: "Generate the lesson" }] },
        { id: "paused", role: "assistant", parts: [{ type: "dynamic-tool", toolName: "native-editor-update-page", toolCallId: "unknown-outcome", state: "input-available", input: { page_id: "lesson-a", expected_revision: 3 } }] },
      ], { broadcast: false })
    })

    async function recover(device: string, receipt?: string) {
      const response = await SELF.fetch(`https://agent.test/agents/hosted-course-agent/${name}`, {
        headers: { authorization: "Bearer test-access-token", upgrade: "websocket", "x-learnfold-origin-id": device },
      })
      const socket = response.webSocket!
      socket.accept()
      const id = crypto.randomUUID()
      const frames: Record<string, unknown>[] = []
      const result = await new Promise<Record<string, unknown>>((resolve, reject) => {
        const deadline = setTimeout(() => reject(Error("Recovery did not settle")), 3_000)
        let submitted = false
        socket.addEventListener("message", (event) => {
          const frame = JSON.parse(event.data as string)
          frames.push(frame)
          if (frame.type === "cf_agent_chat_messages" && !submitted) {
            submitted = true
            socket.send(JSON.stringify({ type: "learnfold_hosted_recover_interrupted", id, workspaceId: "course-a", refreshedPagesReceipt: receipt }))
          }
          if (frame.type === "learnfold_hosted_recovery_result" && frame.id === id) { clearTimeout(deadline); resolve(frame) }
        })
      })
      socket.close(1000)
      return { result, frames }
    }
    const otherDevice = await recover(crypto.randomUUID(), "a".repeat(64))
    expect(otherDevice.result.success).toBe(false)
    expect(String(otherDevice.result.error)).toContain("original device")
    const withoutRefreshedPages = await recover(originID)
    expect(withoutRefreshedPages.result.success).toBe(false)
    expect(String(withoutRefreshedPages.result.error)).toContain("Refresh")
    const originReconnect = await recover(originID, "a".repeat(64))
    expect(originReconnect.frames.find((frame) => frame.type === "learnfold_hosted_session_status")).toMatchObject({ active: true, originatingDevice: true, waitingForTools: true })
    expect(originReconnect.result.success).toBe(true)
    await runInDurableObject(stub, async (agent, state) => {
      const ownership = new HostedTurnOwnership(state.storage)
      expect(await ownership.current()).toBeUndefined()
      expect(await ownership.lastOutcome()).toBe("aborted")
      expect(JSON.stringify(agent.messages)).toContain("output-error")
      expect(JSON.stringify(agent.messages)).toContain("outcome is unknown")
      expect(JSON.stringify(agent.messages)).toContain("No native tool was rerun")
      expect(agent.messages.filter((message) => message.id === "learnfold-interrupted-original-request")).toHaveLength(1)
      expect(await state.storage.get("learnfold.lastRecoveryReceipt")).toMatchObject({ workspaceID: "course-a", checksum: "a".repeat(64) })
      expect(await ownership.admit("other-device", "next-discussion")).toBe(true)
    })
  })
})
