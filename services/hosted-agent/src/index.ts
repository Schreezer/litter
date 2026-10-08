import { Think, Session, defaultContextOverflowClassifier } from "@cloudflare/think"
import type { TurnContext, TurnConfig, ChunkContext, ChatResponseResult } from "@cloudflare/think"
import { routeAgentRequest } from "agents"
import { createCompactFunction } from "agents/experimental/memory/utils"
import { generateText, isToolUIPart } from "ai"

import { ProviderProgress, PROVIDER_STEP_TIMEOUT_MS } from "./provider-progress"
import { HostedTelemetry, observedProviderFetch } from "./telemetry"
import { isAuthorized, unauthorized } from "./auth"
import { COURSE_AGENT_PROMPT, COURSE_DISCUSSION_PROMPT, LEGACY_COURSE_AGENT_PROMPT, QUESTION_CHOICE_CAPABILITY } from "./course-prompt"
import { createHostedModel, DEFAULT_MODEL } from "./provider"
import { authorizeGuestRoute, enforceGuestTurnLimit, guestSession, revenueCatWebhook } from "./guest"
import { HostedTurnOwnership, awaitsClientTools, matchesPendingClientTool } from "./turn-ownership"
export { GuestUsage } from "./guest"

const MAX_WORKSPACE_ID_LENGTH = 128

type HostedEnv = Env & {
  OPENCODE_API_KEY: string
  LEARNFOLD_HOSTED_ACCESS_TOKEN: string
}

function workspaceIDFrom(context: TurnContext): string | null {
  const value = context.body?.workspaceId
  if (typeof value !== "string") return null
  const normalized = value.trim()
  if (!normalized || normalized.length > MAX_WORKSPACE_ID_LENGTH) return null
  return /^[a-zA-Z0-9._-]+$/.test(normalized) ? normalized : null
}

function supportsQuestionChoices(context: TurnContext): boolean {
  const capabilities = context.body?.clientCapabilities
  return Array.isArray(capabilities) && capabilities.includes(QUESTION_CHOICE_CAPABILITY)
}

function courseSystemPrompt(system: string, supportsChoices: boolean): string {
  const prompt = supportsChoices ? COURSE_AGENT_PROMPT : LEGACY_COURSE_AGENT_PROMPT
  // Preserve any extra system instructions Think supplies around our prompt.
  const additional = system.includes(COURSE_AGENT_PROMPT)
    ? system.replace(COURSE_AGENT_PROMPT, "").trim()
    : system.includes(LEGACY_COURSE_AGENT_PROMPT)
      ? system.replace(LEGACY_COURSE_AGENT_PROMPT, "").trim()
      : system.trim()
  return additional ? `${prompt}\n\n${additional}` : prompt
}

function textFromMessage(message: unknown): string | null {
  if (!message || typeof message !== "object") return null
  const record = message as { role?: unknown; content?: unknown }
  if (record.role !== "user") return null
  if (typeof record.content === "string") return record.content
  if (!Array.isArray(record.content)) return null
  return record.content
    .flatMap((part) => {
      if (!part || typeof part !== "object") return []
      const value = part as { type?: unknown; text?: unknown }
      return value.type === "text" && typeof value.text === "string" ? [value.text] : []
    })
    .join("\n")
}

function lastUserText(context: TurnContext): string | null {
  for (let index = context.messages.length - 1; index >= 0; index -= 1) {
    const text = textFromMessage(context.messages[index])
    if (text !== null) return text
  }
  return null
}

type CourseGenerationTurn = "approved" | "directApproved" | "nextLesson"

function courseGenerationTurn(text: string | null): CourseGenerationTurn | null {
  if (text === null) return null
  const normalized = text.trim()
  const tagged = normalized.match(
    /^<learnfold_internal_course_instruction version="1">\s*purpose: (approve_course_plan|generate_course_node)\s*\n[\s\S]*\n<\/learnfold_internal_course_instruction>$/,
  )
  const approval = tagged?.[1] === "approve_course_plan"
    || normalized.startsWith("I approve course plan ")
  if (approval) {
    return normalized.includes("Call native-editor-update-page directly")
      ? "directApproved"
      : "approved"
  }
  return tagged?.[1] === "generate_course_node" ? "nextLesson" : null
}

function generationInstructions(generation: CourseGenerationTurn | null): string {
  if (generation === null) return ""
  const revisionInstruction = generation === "directApproved"
    ? "The phone freshly fetched the exact target. Call native-editor-update-page directly with its supplied page ID and expected revision. Do not fetch unless the update reports a revision conflict."
    : "Use native-editor-fetch for the exact target immediately before native-editor-update-page, and pass the fetched revision as expected_revision. On a revision conflict, fetch again and preserve the learner's changes before retrying."
  return `\n\nThis is a single-page course generation turn. The phone has already created the approved course shell and identified exactly one existing target page in the learner message. ${revisionInstruction} Save the complete lesson content and properties.generation_status = generated in the same native-editor-update-page call. If the update returns an async task handle, poll that handle with native-editor-get-async-task until it reports terminal success; task acceptance is not completion. Do not answer with a completion claim before that exact page update succeeds. Never create, recreate, reorder, or extend the hierarchy, and never update the root, context pages, ancestors, siblings, or later lessons. Folder roll-up status and course readiness belong to Learnfold. If the target is missing or a native tool rejects the request, report the blocker; a chat-only answer does not complete generation.`
}

export class HostedCourseAgent extends Think<HostedEnv> {
  private readonly turnOwnership: HostedTurnOwnership

  constructor(ctx: DurableObjectState, env: HostedEnv) {
    super(ctx, env)
    this.turnOwnership = new HostedTurnOwnership(ctx.storage)
  }

  override async onStart(): Promise<void> {
    // Think installs its protocol dispatcher during startup before invoking
    // this hook. Wrap the installed function here: a constructor/onMessage
    // override is itself wrapped and bypassed by Think's protocol parser.
    await this.reconcileTerminalOwner()
    const connect = this.onConnect.bind(this)
    this.onConnect = async (connection, context) => {
      await this.reconcileTerminalOwner()
      const candidate = context.request.headers.get("x-learnfold-origin-id")
      const originID = candidate && /^[0-9a-f-]{36}$/i.test(candidate) ? candidate.toLowerCase() : connection.id
      connection.setState({ ...connection.state, learnfoldOriginID: originID })
      const owner = await this.turnOwnership.current()
      const legacyPending = owner === undefined && this.messages.some((message) => awaitsClientTools(message.parts))
      connection.send(JSON.stringify({
        type: "learnfold_hosted_session_status",
        active: owner !== undefined || legacyPending,
        originatingDevice: owner?.originID === originID,
        waitingForTools: owner?.waitingForTools ?? legacyPending,
        legacyOriginUnknown: legacyPending,
        terminalStatus: legacyPending ? undefined : await this.turnOwnership.lastOutcome(),
      }))
      // Opening history is read-only. Return persisted text/tool parts before
      // the resume protocol, so a second device never executes replayed tools.
      connection.send(JSON.stringify({ type: "cf_agent_chat_messages", messages: this.messages }))
      return connect(connection, context)
    }
    const dispatch = this.onMessage.bind(this)
    this.onMessage = async (connection, message) => {
      await this.reconcileTerminalOwner()
      let frame: Record<string, unknown> | undefined
      if (typeof message === "string") {
        try { frame = JSON.parse(message) } catch { /* Think reports malformed frames. */ }
      }
      const originID = (connection.state as { learnfoldOriginID?: string } | null)?.learnfoldOriginID ?? connection.id
      if (frame?.type === "learnfold_hosted_recover_interrupted") {
        const requestID = typeof frame.id === "string" ? frame.id : ""
        try {
          if (this.activeRequestID !== undefined) throw new Error("The Hosted task is still running. Wait for it to finish on its original device.")
          const workspaceID = await this.ctx.storage.get<string>("learnfold.workspaceId")
          if (!workspaceID || frame.workspaceId !== workspaceID
            || typeof frame.refreshedPagesReceipt !== "string" || !/^[0-9a-f]{64}$/.test(frame.refreshedPagesReceipt)) {
            throw new Error("Refresh this course's authoritative native pages before recovering the interrupted task.")
          }
          const owner = await this.turnOwnership.beginRecovery(originID)
          if (!owner) throw new Error("Only the original device can recover its interrupted native tool pause.")
          const unknown = "Native tool outcome unknown after the originating device was interrupted. The course pages were refreshed before recovery. Inspect their current content and revision before retrying; this tool was not rerun."
          // addMessages is insert-only for existing IDs. Use Think's durable
          // message update boundary to settle the precise unresolved parts.
          for (const message of [...this.messages]) {
            if (!awaitsClientTools(message.parts)) continue
            await this.updateMessageInHistory({ ...message, parts: message.parts.map((part) => {
              if (!isToolUIPart(part) || (part.state !== "input-streaming"
                && part.state !== "input-available" && part.state !== "approval-requested")) return part
              const { approval: _approval, ...pending } = part
              return { ...pending, input: part.input ?? null, state: "output-error" as const, errorText: unknown }
            }) })
          }
          await this.addMessages([{
            id: `learnfold-interrupted-${owner.requestID}`, role: "assistant",
            parts: [{ type: "text", text: "The previous Hosted task was interrupted. Its native tool outcome is unknown; some changes may already be saved. Learnfold refreshed the current course pages before recovering this conversation. No native tool was rerun. Check the saved lesson before retrying generation." }],
          }])
          await this.ctx.storage.put("learnfold.lastRecoveryReceipt", {
            workspaceID, checksum: frame.refreshedPagesReceipt, recoveredAt: Date.now(),
          })
          await this.turnOwnership.stepFinished(false, owner.requestID, "aborted")
          connection.send(JSON.stringify({ type: "learnfold_hosted_recovery_result", id: requestID, success: true }))
        } catch (error) {
          connection.send(JSON.stringify({ type: "learnfold_hosted_recovery_result", id: requestID, success: false,
            error: error instanceof Error ? error.message : "The interrupted task could not be recovered." }))
        }
        return
      }
      if (frame?.type === "cf_agent_use_chat_request") {
        if (typeof frame.id !== "string") return
        this.activeAdmissions += 1
        let admitted = false
        try {
          const legacyPending = await this.turnOwnership.current() === undefined
            && this.messages.some((message) => awaitsClientTools(message.parts))
          admitted = !legacyPending && await this.turnOwnership.admit(originID, frame.id)
          if (!admitted) {
            connection.send(JSON.stringify({
              type: "cf_agent_use_chat_response", id: frame.id, error: true, done: true,
              body: "This Hosted conversation is still working on its original device. Wait for that task to finish, sync the course, then reopen the discussion to continue.",
            }))
            return
          }
          await dispatch(connection, message)
        } finally {
          this.activeAdmissions -= 1
          // Parse/admission failures may not produce onChatResponse. Release
          // only when no client tool remains unresolved in persisted history.
          const owner = await this.turnOwnership.current()
          if (admitted && this.activeRequestID === undefined && owner?.requestID === frame.id && !owner.waitingForTools) {
            const last = this.messages.findLast((value) => value.role === "assistant")
            await this.turnOwnership.stepFinished(last ? awaitsClientTools(last.parts) : false, frame.id)
          }
        }
        return
      }
      if (frame?.type === "cf_agent_tool_result" || frame?.type === "cf_agent_tool_approval"
        || frame?.type === "cf_agent_chat_request_cancel" || frame?.type === "cf_agent_chat_clear") {
        let owner = await this.turnOwnership.current()
        // Preserve an already running native result across this deployment.
        // No observer/new turn may claim the legacy pause or replay its tool.
        if (!owner && this.messages.some((message) => matchesPendingClientTool(message.parts, frame))) {
          await this.turnOwnership.admit(originID, `legacy-native-${frame.toolCallId}`, true)
          owner = await this.turnOwnership.current()
        }
        // Observing devices may read every saved tool result, but only the
        // originating device may supply results or cancel the active task.
        if (frame.type === "cf_agent_chat_clear" || !owner || owner.originID !== originID || owner.recovering) return
      }
      return dispatch(connection, message)
    }
  }

  override async onChatResponse(result: ChatResponseResult): Promise<void> {
    await this.turnOwnership.stepFinished(
      result.status === "completed" && awaitsClientTools(result.message.parts), undefined, result.status,
    )
  }

  private async reconcileTerminalOwner(): Promise<void> {
    await this.turnOwnership.reconcileTerminalOutcome(
      () => this.activeRequestID !== undefined || this.activeAdmissions > 0,
      () => this.messages.some((message) => awaitsClientTools(message.parts)),
    )
  }

  private readonly providerProgress = new ProviderProgress()
  private readonly telemetry = new HostedTelemetry(() => this.ctx.id.toString())
  // Think 0.15.1 omits requestId from TurnContext. The admitted-turn lifecycle
  // keeps the same ID around reactive compaction retries (continuation:false).
  private activeRequestID?: string
  private activeAdmissions = 0
  override observability = {
    emit: (event: { type: string; payload: Record<string, unknown> }) => {
      const requestID = typeof event.payload.requestId === "string" ? event.payload.requestId : undefined
      if (event.type === "chat:turn:start") this.activeRequestID = requestID
      this.telemetry.lifecycle(event)
      if (event.type === "chat:turn:finish" && this.activeRequestID === requestID) {
        this.activeRequestID = undefined
      }
    },
  }

  override onChunk(context: ChunkContext) {
    this.telemetry.chunk(context.chunk.type)
  }

  // Pinned Think 0.15.1 exposes this protected hook. Keep the real Think stream
  // regression test when upgrading: its watchdog must receive activity chunks.
  protected override _transformInferenceResult(result: Parameters<ProviderProgress["wrap"]>[0]) {
    return this.providerProgress.wrap(result)
  }

  override workspaceBash = false
  override includeMcpTools = false
  override chatRecovery = {
    maxAttempts: 4,
    terminalMessage: "The hosted agent was interrupted. Your conversation is saved; please try again.",
  }
  override chatStreamStallTimeoutMs = 120_000
  override contextOverflow = {
    reactive: true,
    proactive: { maxInputTokens: 96_000 },
  }
  override classifyChatError = defaultContextOverflowClassifier

  override getModel() {
    return createHostedModel(this.env.OPENCODE_API_KEY,
      observedProviderFetch(() => this.telemetry.providerObservation(), fetch,
        () => this.providerProgress.observer()),
      this.ctx.id.toString())
  }

  override getSystemPrompt(): string {
    return LEGACY_COURSE_AGENT_PROMPT
  }

  override getSkills() {
    return []
  }

  override configureSession(session: Session): Session {
    return session
      .onCompaction(createCompactFunction({
        summarize: async (prompt) => {
          const result = await generateText({ model: this.getModel(), prompt })
          return result.text
        },
        protectHead: 3,
        tailTokenBudget: 18_000,
        minTailMessages: 4,
      }))
      .compactAfter(72_000)
      .withCachedPrompt()
  }

  override async beforeTurn(context: TurnContext): Promise<TurnConfig> {
    await this.turnOwnership.resumeInference(this.activeRequestID)
    // Think's tool auto-continuations have no request body. Keep the binding
    // and generation policy durable across object restarts and compaction.
    // A genuinely new request replaces the policy; a retry of the same
    // admitted request preserves it even if compaction summarized its marker.
    const requestedGeneration = courseGenerationTurn(lastUserText(context))
    const requestID = this.activeRequestID
    // Unlike model-visible messages, this durable UI history retains message
    // IDs. Recovery may admit a new request for the same learner submission.
    const userMessageID = this.messages.findLast((message) => message.role === "user")?.id
    const { workspaceID, generation, isDiscussion, questionChoices } = await this.ctx.storage.transaction(async (storage) => {
      const saved = await storage.get<string>("learnfold.workspaceId")
      const supplied = workspaceIDFrom(context)
      const isBodylessContinuation = context.continuation && context.body === undefined
      const resolved = isBodylessContinuation ? saved : supplied
      // Discussions withhold present_course_plan from their course tools.
      // Body-less continuations may omit tools, so keep the role durable.
      const savedRole = await storage.get<string>("learnfold.threadRole")
      const suppliedRole = isDiscussionToolSet(context) ? "discussion" : "course"
      const role = isBodylessContinuation ? savedRole ?? suppliedRole : suppliedRole
      if (role !== savedRole) await storage.put("learnfold.threadRole", role)
      if (!resolved) {
        throw new Error("A valid Learnfold workspaceId is required for every hosted turn.")
      }
      if (saved && saved !== resolved) {
        throw new Error("This Hosted conversation belongs to a different course workspace.")
      }
      if (!saved) await storage.put("learnfold.workspaceId", resolved)
      const savedGeneration = await storage.get<CourseGenerationTurn>("learnfold.generationTurn")
      const savedRequestID = await storage.get<string>("learnfold.generationRequestId")
      const savedUserMessageID = await storage.get<string>("learnfold.generationUserMessageId")
      const retriesSameRequest = requestID !== undefined && requestID === savedRequestID
      const retriesSameMessage = userMessageID !== undefined && userMessageID === savedUserMessageID
      const generation = context.continuation || retriesSameRequest || retriesSameMessage
        ? savedGeneration ?? requestedGeneration
        : requestedGeneration
      if (generation !== null) {
        await storage.put("learnfold.generationTurn", generation)
        if (requestID !== undefined) {
          await storage.put("learnfold.generationRequestId", requestID)
        } else {
          await storage.delete("learnfold.generationRequestId")
        }
        if (userMessageID !== undefined) {
          await storage.put("learnfold.generationUserMessageId", userMessageID)
        } else {
          await storage.delete("learnfold.generationUserMessageId")
        }
      } else {
        await storage.delete([
          "learnfold.generationTurn", "learnfold.generationRequestId", "learnfold.generationUserMessageId",
        ])
      }
      // A tool auto-continuation has no request body. Keep the client renderer
      // capability with its turn so a tool call cannot switch prompt formats.
      const savedChoices = await storage.get<boolean>("learnfold.questionChoices")
      const questionChoices = context.continuation
        ? savedChoices === true
        : supportsQuestionChoices(context)
      if (savedChoices !== questionChoices) {
        await storage.put("learnfold.questionChoices", questionChoices)
      }
      return { workspaceID: resolved, generation, isDiscussion: role === "discussion", questionChoices }
    })
    await enforceGuestTurnLimit(this.name, this.env)
    const clientToolNames = Object.keys(context.tools).filter((name) =>
      name === "present_course_plan" || name.startsWith("native-editor-"),
    )
    const activeTools = generation !== null
      ? clientToolNames.filter((name) =>
          name === "native-editor-update-page"
            || name === "native-editor-fetch"
            || name === "native-editor-get-async-task",
        )
      : clientToolNames
    this.telemetry.prepared(context.continuation, context.messages.length, activeTools.length)
    return {
      instructions: `${courseSystemPrompt(context.system, questionChoices)}${isDiscussion ? `\n\n${COURSE_DISCUSSION_PROMPT}` : ""}\n\nCurrent Learnfold workspace_id: ${workspaceID}${generationInstructions(generation)}`,
      activeTools,
      maxSteps: this.name.startsWith("guest-") ? 12 : 24,
      sendReasoning: false,
      // Genuine activity extends idle waits, but each model step stays bounded.
      timeout: { stepMs: PROVIDER_STEP_TIMEOUT_MS },
    }
  }
}

/// A turn whose course tools omit present_course_plan belongs to a passage or
/// page discussion inside an existing course.
function isDiscussionToolSet(context: TurnContext): boolean {
  const names = Object.keys(context.tools)
  return names.some((name) => name.startsWith("native-editor-"))
    && !names.includes("present_course_plan")
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  })
}

export default {
  async fetch(request: Request, env: HostedEnv): Promise<Response> {
    const url = new URL(request.url)
    if (url.pathname === "/guest-session" && request.method === "POST") {
      return guestSession(request, env, env.LEARNFOLD_HOSTED_ACCESS_TOKEN)
    }
    if (url.pathname === "/revenuecat/webhook" && request.method === "POST") {
      return revenueCatWebhook(request, env)
    }
    if (url.pathname === "/health" && request.method === "GET") {
      if (!await isAuthorized(request, env.LEARNFOLD_HOSTED_ACCESS_TOKEN)) return unauthorized()
      return json({
        ok: true,
        runtime: "cloudflare-think",
        model: DEFAULT_MODEL,
        protocol: "cf-agent-chat-v1",
        capabilities: ["durable-session", "stream-resume", "auto-compaction", "client-tools"],
      })
    }

    if (!await isAuthorized(request, env.LEARNFOLD_HOSTED_ACCESS_TOKEN)) {
      // Guest tokens are only minted to entitled subscribers when the free beta is
      // off, and every turn re-checks the entitlement, so no flag check here.
      const guestRequest = await authorizeGuestRoute(request, env.LEARNFOLD_HOSTED_ACCESS_TOKEN)
      if (!guestRequest) return unauthorized()
      return (await routeAgentRequest(guestRequest, env)) ?? json({ error: "not_found" }, 404)
    }
    return (await routeAgentRequest(request, env)) ?? json({ error: "not_found" }, 404)
  },
} satisfies ExportedHandler<HostedEnv>
