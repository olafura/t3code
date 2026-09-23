defmodule T3.Orchestration.Entities do
  @moduledoc """
  Builders for the v2 entities a turn produces, in the exact JSON shape of the
  contracts in `packages/contracts/src/orchestrationV2.ts`. Clients decode them
  strictly, so every required field is present, `nil` stands for null, and times
  are ISO strings with millisecond precision.
  """

  @codex_capabilities %{
    "sessions" => %{
      "supportsMultipleProviderThreadsPerSession" => true,
      "supportsModelSwitchInSession" => true,
      "supportsProviderSwitchingViaHandoff" => false,
      "supportsRuntimeModeSwitchInSession" => true,
      "pendingRequestsSurviveRestart" => false
    },
    "threads" => %{
      "canCreateEmptyThread" => true,
      "canReadThreadSnapshot" => true,
      "canRollbackThread" => false,
      "canForkThread" => false,
      "canForkFromTurn" => false,
      "canForkFromSubagentThread" => false,
      "exposesNativeThreadId" => true
    },
    "turns" => %{
      "exposesNativeTurnId" => true,
      "emitsTurnStarted" => true,
      "emitsTurnCompleted" => true,
      "supportsInterrupt" => true,
      "supportsActiveSteering" => false,
      "supportsSteeringByInterruptRestart" => false,
      "supportsQueuedMessages" => false,
      "terminalStatusQuality" => "strong"
    },
    "streaming" => %{
      "streamsAssistantText" => true,
      "streamsReasoning" => true,
      "streamsToolOutput" => true,
      "streamsPlanText" => false,
      "emitsMessageCompleted" => true
    },
    "tools" => %{
      "exposesToolItemIds" => true,
      "emitsToolStarted" => true,
      "emitsToolCompleted" => true,
      "emitsToolOutput" => true,
      "supportsMcpTools" => false,
      "supportsDynamicToolCallbacks" => false
    },
    "approvals" => %{
      "supportsCommandApproval" => false,
      "supportsFileReadApproval" => false,
      "supportsFileChangeApproval" => false,
      "supportsApplyPatchApproval" => false,
      "approvalsHaveNativeRequestIds" => true,
      "approvalCallbacksAreLiveOnly" => true,
      "approvalsCanOriginateFromSubagents" => false
    },
    "planning" => %{
      "emitsPlanUpdated" => false,
      "emitsTodoList" => false,
      "emitsProposedPlan" => false,
      "supportsStructuredQuestions" => false,
      "planDeltasHaveItemIds" => false
    },
    "subagents" => %{
      "supportsSubagents" => false,
      "exposesSubagentThreadIds" => false,
      "emitsSubagentLifecycle" => false,
      "canWaitForSubagents" => false,
      "canCloseSubagents" => false,
      "canForkSubagentThread" => false
    },
    "context" => %{
      "acceptsSystemContext" => false,
      "acceptsDeveloperContext" => false,
      "acceptsSyntheticUserContext" => false,
      "canGenerateSummaries" => false,
      "canConsumeHandoffSummaries" => false,
      "supportsDeltaHandoff" => false,
      "supportsFullThreadHandoff" => false,
      "maxRecommendedHandoffChars" => nil
    },
    "checkpointing" => %{
      "appCanCheckpointFilesystem" => false,
      "supportsNestedCheckpointScopes" => false,
      "providerCanRollbackConversation" => false,
      "providerRollbackReturnsSnapshot" => false,
      "providerCanReadConversationSnapshot" => false
    },
    "identity" => %{
      "nativeThreadIds" => "strong",
      "nativeTurnIds" => "strong",
      "nativeItemIds" => "strong",
      "nativeRequestIds" => "strong"
    }
  }

  @spec now() :: String.t()
  def now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  @spec new_id(String.t()) :: String.t()
  def new_id(prefix), do: "#{prefix}:#{T3.Environment.uuid4()}"

  def provider_ref(native_id),
    do: %{"driver" => "codex", "nativeId" => native_id, "strength" => "strong"}

  def provider_session(id, cwd, model, at) do
    %{
      "id" => id,
      "driver" => "codex",
      "providerInstanceId" => "codex",
      "status" => "ready",
      "cwd" => cwd,
      "model" => model,
      "capabilities" => @codex_capabilities,
      "createdAt" => at,
      "updatedAt" => at,
      "lastError" => nil
    }
  end

  def provider_thread(id, thread_id, session_id, run_ordinal, at) do
    %{
      "id" => id,
      "driver" => "codex",
      "providerInstanceId" => "codex",
      "providerSessionId" => session_id,
      "appThreadId" => thread_id,
      "ownerNodeId" => nil,
      "nativeThreadRef" => nil,
      "nativeConversationHeadRef" => nil,
      "status" => "not_loaded",
      "firstRunOrdinal" => run_ordinal,
      "lastRunOrdinal" => run_ordinal,
      "handoffIds" => [],
      "forkedFrom" => nil,
      "createdAt" => at,
      "updatedAt" => at
    }
  end

  def run(ids, ordinal, model_selection, at) do
    %{
      "id" => ids.run,
      "threadId" => ids.thread,
      "ordinal" => ordinal,
      "providerInstanceId" => "codex",
      "modelSelection" => model_selection,
      "providerThreadId" => ids.provider_thread,
      "userMessageId" => ids.message,
      "rootNodeId" => ids.root_node,
      "activeAttemptId" => ids.attempt,
      "status" => "starting",
      "queuePosition" => nil,
      "requestedAt" => at,
      "startedAt" => nil,
      "completedAt" => nil,
      "checkpointId" => nil,
      "contextHandoffId" => nil
    }
  end

  def attempt(ids) do
    %{
      "id" => ids.attempt,
      "runId" => ids.run,
      "attemptOrdinal" => 1,
      "rootNodeId" => ids.root_node,
      "providerInstanceId" => "codex",
      "providerThreadId" => ids.provider_thread,
      "providerTurnId" => nil,
      "reason" => "initial",
      "status" => "pending",
      "startedAt" => nil,
      "completedAt" => nil
    }
  end

  def node(ids, id, kind, status, at, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "threadId" => ids.thread,
        "runId" => ids.run,
        "parentNodeId" => if(kind == "root_turn", do: nil, else: ids.root_node),
        "rootNodeId" => ids.root_node,
        "kind" => kind,
        "status" => status,
        "countsForRun" => kind == "root_turn",
        "providerThreadId" => ids.provider_thread,
        "providerTurnId" => Map.get(ids, :provider_turn),
        "nativeItemRef" => nil,
        "runtimeRequestId" => nil,
        "checkpointScopeId" => nil,
        "startedAt" => at,
        "completedAt" => nil
      },
      extra
    )
  end

  def provider_turn(ids, native_turn_id, ordinal, at) do
    %{
      "id" => ids.provider_turn,
      "providerThreadId" => ids.provider_thread,
      "nodeId" => ids.root_node,
      "runAttemptId" => ids.attempt,
      "nativeTurnRef" => provider_ref(native_turn_id),
      "ordinal" => ordinal,
      "status" => "running",
      "startedAt" => at,
      "completedAt" => nil
    }
  end

  def message(ids, id, role, text, streaming, at, extra \\ %{}) do
    Map.merge(
      %{
        "createdBy" => if(role == "user", do: "user", else: "agent"),
        "creationSource" => if(role == "user", do: "web", else: "provider"),
        "id" => id,
        "threadId" => ids.thread,
        "runId" => ids.run,
        "nodeId" => ids.root_node,
        "role" => role,
        "text" => text,
        "attachments" => [],
        "streaming" => streaming,
        "createdAt" => at,
        "updatedAt" => at
      },
      extra
    )
  end

  @doc "A turn item of `type` with the shared base fields and the type's own `fields`."
  def turn_item(ids, id, type, ordinal, status, at, fields) do
    Map.merge(
      %{
        "id" => id,
        "threadId" => ids.thread,
        "runId" => ids.run,
        "nodeId" => Map.get(ids, :node, ids.root_node),
        "providerThreadId" => ids.provider_thread,
        "providerTurnId" => Map.get(ids, :provider_turn),
        "nativeItemRef" => nil,
        "parentItemId" => nil,
        "ordinal" => ordinal,
        "status" => status,
        "title" => nil,
        "startedAt" => at,
        "completedAt" =>
          if(status in ["completed", "failed", "cancelled", "interrupted"], do: at),
        "updatedAt" => at,
        "type" => type
      },
      fields
    )
  end

  @doc "A new app thread (`OrchestrationV2AppThread`)."
  def thread(input, at) do
    id = input["threadId"]

    %{
      "createdBy" => "user",
      "creationSource" => input["creationSource"] || "web",
      "id" => id,
      "projectId" => input["projectId"],
      "title" => input["title"] || "New thread",
      "providerInstanceId" => "codex",
      "modelSelection" => input["modelSelection"],
      "runtimeMode" => input["runtimeMode"] || "full-access",
      "interactionMode" => input["interactionMode"] || "default",
      "branch" => get_in(input, ["workspaceStrategy", "branch"]),
      "worktreePath" => nil,
      "activeProviderThreadId" => nil,
      "lineage" => %{"parentThreadId" => nil, "relationshipToParent" => nil, "rootThreadId" => id},
      "forkedFrom" => nil,
      "createdAt" => at,
      "updatedAt" => at,
      "archivedAt" => nil,
      "settledOverride" => nil,
      "settledAt" => nil,
      "lastVisitedAt" => nil,
      "deletedAt" => nil
    }
  end
end
