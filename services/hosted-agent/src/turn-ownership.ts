/** Native course tools execute on one device. Keep their turn owned through
 * Think's tool pauses and continuations, including Durable Object restarts. */
export type HostedTurnOwner = {
  originID: string
  requestID: string
  waitingForTools: boolean
  recovering?: boolean
  inferenceRequestID?: string
}

const OWNER_KEY = "learnfold.activeTurnOwner"
const OUTCOME_KEY = "learnfold.lastTurnOutcome"
export type HostedTurnOutcome = "completed" | "error" | "aborted"

export class HostedTurnOwnership {
  constructor(private readonly storage: DurableObjectStorage) {}

  async current(): Promise<HostedTurnOwner | undefined> {
    return this.storage.get<HostedTurnOwner>(OWNER_KEY)
  }

  async lastOutcome(): Promise<HostedTurnOutcome | undefined> {
    return this.storage.get<HostedTurnOutcome>(OUTCOME_KEY)
  }

  async resumeInference(requestID?: string): Promise<void> {
    await this.storage.transaction(async (storage) => {
      const owner = await storage.get<HostedTurnOwner>(OWNER_KEY)
      if (owner?.recovering) throw new Error("The interrupted Hosted turn is being recovered without replaying its native tools.")
      if (owner) await storage.put(OWNER_KEY, { ...owner, waitingForTools: false,
        ...(requestID ? { inferenceRequestID: requestID } : {}) })
    })
  }

  /** Think 0.15.1's exhausted and already-terminal wake paths bypass
   * onChatResponse. Reconcile only its committed terminal evidence; a queued
   * recovery or a live inference must keep ownership. These pinned SQLite/key
   * seams are covered by real SDK exhaustion and continuation regressions. */
  async reconcileTerminalOutcome(isLive: () => boolean, hasPendingTools: () => boolean): Promise<void> {
    await this.storage.transaction(async (storage) => {
      let owner = await storage.get<HostedTurnOwner>(OWNER_KEY)
      if (!owner || isLive() || owner.recovering) return
      if (await storage.get("cf:chat:recovering") !== undefined) return
      const terminal = await storage.get<unknown>("cf:chat:last-terminal")
      const terminalRequestID = terminal && typeof terminal === "object" && "requestId" in terminal
        && typeof terminal.requestId === "string" ? terminal.requestId : undefined
      const stream = this.storage.sql.exec<{ request_id: string; status: string }>(
        "SELECT request_id, status FROM cf_ai_chat_stream_metadata ORDER BY created_at DESC, rowid DESC LIMIT 1",
      ).toArray()[0]
      // Upgrade the first ownership release's records, which did not retain
      // continuation IDs. Its unique admitted root must have a stream row;
      // ownership then excludes later user turns, so the newest row belongs
      // to that logical turn. Never infer for pre-stream or native-pause owners.
      if (!owner.inferenceRequestID && !owner.waitingForTools && stream
        && this.storage.sql.exec("SELECT 1 FROM cf_ai_chat_stream_metadata WHERE request_id = ? LIMIT 1", owner.requestID).toArray().length > 0) {
        owner = { ...owner, inferenceRequestID: stream.request_id }
        if (isLive()) return
        await storage.put(OWNER_KEY, owner)
      }
      const inferenceRequestID = owner.inferenceRequestID ?? owner.requestID
      const failed = terminalRequestID === inferenceRequestID
      const streamOutcome = stream?.request_id === inferenceRequestID
        && (stream.status === "completed" || stream.status === "error") ? stream.status : undefined
      // A newer continuation's streaming row always outranks an older root's
      // completed row, including a restart before its recovery marker exists.
      if ((!failed && !streamOutcome) || isLive()) return
      if (hasPendingTools()) {
        await storage.put(OWNER_KEY, { ...owner, waitingForTools: true })
      } else {
        await storage.put(OUTCOME_KEY, failed ? "error" : streamOutcome!)
        await storage.delete(OWNER_KEY)
      }
    })
  }

  async beginRecovery(originID: string): Promise<HostedTurnOwner | undefined> {
    return this.storage.transaction(async (storage) => {
      const owner = await storage.get<HostedTurnOwner>(OWNER_KEY)
      if (!owner || owner.originID !== originID || !owner.waitingForTools) return undefined
      await storage.put(OWNER_KEY, { ...owner, recovering: true })
      return owner
    })
  }

  async admit(originID: string, requestID: string, waitingForTools = false): Promise<boolean> {
    return this.storage.transaction(async (storage) => {
      if (await storage.get(OWNER_KEY)) return false
      await storage.put(OWNER_KEY, { originID, requestID, waitingForTools })
      return true
    })
  }

  async stepFinished(waitingForTools: boolean, expectedRequestID?: string, outcome: HostedTurnOutcome = "error"): Promise<void> {
    await this.storage.transaction(async (storage) => {
      const owner = await storage.get<HostedTurnOwner>(OWNER_KEY)
      if (!owner || (expectedRequestID !== undefined && owner.requestID !== expectedRequestID)) return
      if (waitingForTools) await storage.put(OWNER_KEY, { ...owner, waitingForTools: true })
      else {
        await storage.put(OUTCOME_KEY, outcome)
        await storage.delete(OWNER_KEY)
      }
    })
  }
}

export function awaitsClientTools(parts: readonly unknown[]): boolean {
  return parts.some((part) => {
    if (!part || typeof part !== "object") return false
    const value = part as { type?: unknown; state?: unknown }
    return typeof value.type === "string"
      && (value.type === "dynamic-tool" || value.type.startsWith("tool-"))
      && ["input-streaming", "input-available", "approval-requested"].includes(String(value.state))
  })
}

/** A pre-ownership deployment may already have a native tool paused. Only its
 * exact pending result/approval can adopt that pause; opening history cannot. */
export function matchesPendingClientTool(parts: readonly unknown[], frame: Record<string, unknown>): boolean {
  if (typeof frame.toolCallId !== "string") return false
  return parts.some((part) => {
    if (!part || typeof part !== "object") return false
    const value = part as { type?: unknown; state?: unknown; toolCallId?: unknown; toolName?: unknown }
    if (value.toolCallId !== frame.toolCallId || typeof value.type !== "string"
      || (value.type !== "dynamic-tool" && !value.type.startsWith("tool-"))) return false
    if (frame.type === "cf_agent_tool_approval") {
      return typeof frame.approved === "boolean"
        && (value.state === "input-available" || value.state === "approval-requested")
    }
    const toolName = value.type === "dynamic-tool" ? value.toolName : value.type.slice(5)
    return frame.type === "cf_agent_tool_result" && value.state === "input-available"
      && frame.toolName === toolName
      && (frame.state === "output-available" || frame.state === "output-error")
  })
}
