import { describe, expect, it } from "bun:test";
import { CliRenderEvents, type Renderable, ScrollBoxRenderable } from "@opentui/core";
import { setRendererCapabilities } from "@opentui/core/testing";
import { testRender } from "@opentui/react/test-utils";
import { installKittyImageExtension, type RgbaImage } from "@t3tools/opentui-image";
import * as React from "react";

import {
  DEFAULT_SERVER_SETTINGS,
  type TerminalMetadataStreamEvent,
  type VcsStatusResult,
} from "@t3tools/contracts";

import type { OrchestrationShellSnapshot, OrchestrationThread, TuiClient } from "../connection.ts";
import type { HerdrTuiHost } from "../herdr/host.ts";
import type { HerdrSessionSnapshot } from "../herdr/protocol.ts";
import { ChatView } from "./ChatView.tsx";

const PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

interface Deferred<T> {
  readonly promise: Promise<T>;
  readonly resolve: (value: T) => void;
  readonly reject: (reason: unknown) => void;
}

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function findScrollBox(root: Renderable): ScrollBoxRenderable | null {
  const queue = [root];
  while (queue.length > 0) {
    const renderable = queue.shift();
    if (!renderable) continue;
    if (renderable instanceof ScrollBoxRenderable) return renderable;
    queue.push(...renderable.getChildren());
  }
  return null;
}

const project = {
  id: "p1",
  title: "Project one",
  workspaceRoot: "/workspace/project-one",
  defaultModelSelection: { instanceId: "codex", model: "gpt-5" },
  createdAt: "2026-07-13T00:00:00.000Z",
  updatedAt: "2026-07-13T00:00:00.000Z",
};

const projectTwo = {
  ...project,
  id: "p2",
  title: "Project two",
  workspaceRoot: "/workspace/project-two",
  defaultModelSelection: { instanceId: "codex", model: "gpt-5-mini" },
};

function thread(activities: OrchestrationThread["activities"] = []): OrchestrationThread {
  return {
    id: "t1",
    projectId: "p1",
    title: "Thread one",
    interactionMode: "default",
    runtimeMode: "full-access",
    branch: "main",
    worktreePath: null,
    updatedAt: "2026-07-13T00:00:00.000Z",
    session: { status: "idle" },
    latestTurn: null,
    messages: [],
    activities,
    checkpoints: [],
    modelSelection: { instanceId: "codex", model: "gpt-5" },
    proposedPlans: [],
    hasMoreActivities: false,
  } as unknown as OrchestrationThread;
}

function shell(
  threads: OrchestrationShellSnapshot["threads"] = [
    {
      id: "t1",
      projectId: "p1",
      title: "Thread one",
      updatedAt: "2026-07-13T00:00:00.000Z",
      session: { status: "idle" },
    },
  ] as unknown as OrchestrationShellSnapshot["threads"],
  projects: OrchestrationShellSnapshot["projects"] = [
    project,
  ] as unknown as OrchestrationShellSnapshot["projects"],
): OrchestrationShellSnapshot {
  return {
    projects,
    threads,
  } as unknown as OrchestrationShellSnapshot;
}

function fakeClient({
  detail,
  shellSnapshot = shell(),
  sendReply = () => Promise.resolve(),
  respondUserInput = () => Promise.resolve(),
  createProject = async () => "p-new" as never,
  createThread = async () => "t-new" as never,
  terminalClear = async () => {},
  terminalRestart = async () => {},
  setInteractionMode = async () => {},
  vcsStatus,
  runGitPull = async () => {},
  getAttachmentUrl = async () => null,
  getAttachmentImage = async () => null,
  listRefs = async () =>
    ({
      refs: [
        {
          name: "main",
          current: true,
          isDefault: true,
          worktreePath: null,
        },
      ],
      isRepo: true,
      hasPrimaryRemote: true,
      nextCursor: null,
      totalCount: 1,
    }) as never,
  switchRef = async (_cwd: string, refName: string) => ({ refName }) as never,
  listModels = async () =>
    [
      {
        instanceId: "codex",
        model: "gpt-5",
        label: "GPT-5",
        providerLabel: "Codex",
        capabilities: null,
      },
    ] as never,
  terminalMetadata,
}: {
  readonly detail: OrchestrationThread;
  readonly shellSnapshot?: OrchestrationShellSnapshot;
  readonly sendReply?: TuiClient["sendReply"];
  readonly respondUserInput?: TuiClient["respondUserInput"];
  readonly createProject?: TuiClient["createProject"];
  readonly createThread?: TuiClient["createThread"];
  readonly terminalClear?: TuiClient["terminalClear"];
  readonly terminalRestart?: TuiClient["terminalRestart"];
  readonly setInteractionMode?: TuiClient["setInteractionMode"];
  readonly vcsStatus?: VcsStatusResult;
  readonly runGitPull?: TuiClient["runGitPull"];
  readonly getAttachmentUrl?: TuiClient["getAttachmentUrl"];
  readonly getAttachmentImage?: TuiClient["getAttachmentImage"];
  readonly listRefs?: TuiClient["listRefs"];
  readonly switchRef?: TuiClient["switchRef"];
  readonly listModels?: TuiClient["listModels"];
  readonly terminalMetadata?: TerminalMetadataStreamEvent;
}): {
  readonly client: TuiClient;
  readonly connect: () => void;
  readonly subscribedThreadIds: string[];
  readonly subscribedTerminalIds: string[];
} {
  let shellSubscriber: ((snapshot: OrchestrationShellSnapshot) => void) | null = null;
  const subscribedThreadIds: string[] = [];
  const subscribedTerminalIds: string[] = [];
  const client = {
    subscribeShell: (onSnapshot: (snapshot: OrchestrationShellSnapshot) => void) => {
      shellSubscriber = onSnapshot;
      return () => {
        shellSubscriber = null;
      };
    },
    subscribeThread: (threadId: string) => {
      subscribedThreadIds.push(threadId);
      return () => {};
    },
    peekThread: () => detail,
    subscribeVcsStatus: (_cwd: string, onStatus: (status: VcsStatusResult) => void) => {
      if (vcsStatus) onStatus(vcsStatus);
      return () => {};
    },
    subscribeTerminalMetadata: (onEvent: (event: TerminalMetadataStreamEvent) => void) => {
      if (terminalMetadata) onEvent(terminalMetadata);
      return () => {};
    },
    sendReply,
    respondUserInput,
    createProject,
    createThread,
    subscribeTerminal: (input: Parameters<TuiClient["subscribeTerminal"]>[0]) => {
      subscribedTerminalIds.push(input.terminalId);
      return () => {};
    },
    terminalWrite: async () => {},
    terminalResize: async () => {},
    terminalClear,
    terminalRestart,
    setInteractionMode,
    terminalClose: async () => {},
    listModels,
    getServerConfig: async () => ({ settings: DEFAULT_SERVER_SETTINGS }) as never,
    listRefs,
    switchRef,
    getThreadActivities: async () => ({ activities: [], hasMore: false }),
    getAttachmentUrl,
    getAttachmentImage,
    runGitStackedAction: async () => {},
    runGitPull,
  } as unknown as TuiClient;
  return {
    client,
    connect: () => shellSubscriber?.(shellSnapshot),
    subscribedThreadIds,
    subscribedTerminalIds,
  };
}

async function selectThread(
  setup: Awaited<ReturnType<typeof testRender>>,
  connect: () => void,
): Promise<void> {
  await React.act(async () => {
    await setup.renderOnce();
    connect();
    await setup.renderOnce();
    await setup.flush();
  });
  await setup.waitForFrame((frame) => frame.includes("Project one"));

  // Selecting a project automatically opens its new-thread composer and expands
  // the project, so Alt+Down can move directly into its first thread.
  await React.act(async () => {
    setup.mockInput.pressKey("\x1b\x1b[B");
    await setup.renderOnce();
  });
  await setup.waitForFrame(
    (frame) => frame.includes("Thread one") && !frame.includes("Enter to expand"),
  );
}

describe("ChatView responsive shell", () => {
  it("Given the desktop layout, the projects sidebar spans the full terminal height", async () => {
    const fake = fakeClient({ detail: thread() });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });
    await selectThread(setup, fake.connect);
    const lines = setup.captureCharFrame().split("\n");
    expect(lines[27]?.[0]).toBe("╰");
    expect(lines[27]?.[33]).toBe("╯");
    setup.renderer.destroy();
  });

  it("Given an empty prompt, the composer presents a multiline writing surface", async () => {
    const fake = fakeClient({ detail: thread() });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });
    await selectThread(setup, fake.connect);
    const lines = setup.captureCharFrame().split("\n");
    const promptRow = lines.findIndex((line) => line.includes("Ask anything"));
    const footerRow = lines.findIndex((line) => line.includes("model gpt-5"));
    expect(promptRow).toBeGreaterThanOrEqual(0);
    expect(footerRow - promptRow).toBeGreaterThanOrEqual(4);
    setup.renderer.destroy();
  });

  it("Given a narrow terminal, the sidebar auto-collapses and Find opens it off-canvas", async () => {
    const fake = fakeClient({ detail: thread() });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 72,
      height: 24,
    });
    await React.act(async () => {
      await setup.renderOnce();
      fake.connect();
      await setup.renderOnce();
      await setup.flush();
    });
    expect(setup.captureCharFrame()).not.toContain("Projects");
    await React.act(async () => {
      setup.mockInput.pressKey("f", { ctrl: true });
      await setup.renderOnce();
    });
    const sidebarFrame = await setup.waitForFrame((frame) => frame.includes("Search projects"));
    expect(sidebarFrame).toContain("Projects");
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => !frame.includes("Projects"));
    setup.renderer.destroy();
  });

  it("Given a large wrapped prompt and an open terminal, the terminal keeps a usable viewport", async () => {
    const fake = fakeClient({ detail: thread() });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });
    await selectThread(setup, fake.connect);
    await React.act(async () => {
      await setup.mockInput.typeText("word ".repeat(120));
      setup.mockInput.pressKey("e", { ctrl: true });
      await setup.renderOnce();
    });
    const frame = await setup.waitForFrame((current) => current.includes("Terminal · Thread one"));
    const lines = frame.split("\n");
    const terminalTop = lines.findIndex((line) => line.includes("Terminal · Thread one"));
    const terminalBottom = lines.findIndex(
      (line, index) => index > terminalTop && line.slice(34).includes("└"),
    );
    expect(terminalTop).toBeGreaterThanOrEqual(0);
    expect(terminalBottom - terminalTop).toBeGreaterThanOrEqual(5);
    expect(terminalBottom).toBeLessThan(27);
    setup.renderer.destroy();
  });
});

describe("ChatView Herdr host", () => {
  it("Given a Herdr Space, the hosted timeline toggles T3 navigation and opens one synced native terminal pane", async () => {
    const snapshot = {
      version: "0.7.5",
      protocol: 17,
      focused_workspace_id: "w1",
      focused_tab_id: "w1:t1",
      focused_pane_id: "w1:p2",
      workspaces: [
        {
          workspace_id: "w1",
          number: 1,
          label: "Project one",
          focused: true,
          pane_count: 2,
          tab_count: 1,
          active_tab_id: "w1:t1",
          agent_status: "idle",
          worktree: {
            repo_key: "project-one",
            repo_name: "project-one",
            repo_root: "/workspace/project-one",
            checkout_path: "/workspace/project-one",
            is_linked_worktree: false,
          },
        },
      ],
      tabs: [],
      panes: [],
      layouts: [],
      agents: [
        {
          pane_id: "w1:p2",
          terminal_id: "terminal-2",
          workspace_id: "w1",
          tab_id: "w1:t1",
          focused: true,
          agent_status: "idle",
          revision: 7,
          agent: "codex",
          display_agent: "Reviewer",
          cwd: "/workspace/project-one",
        },
      ],
    } as const satisfies HerdrSessionSnapshot;
    const reports: Array<Parameters<HerdrTuiHost["reportThread"]>[0]> = [];
    const openedTerminals: string[] = [];
    let herdrConnected = false;
    let notifyHost = () => {};
    const host = {
      kind: "herdr",
      workspaceId: "w1",
      workspaceCwd: "/workspace/project-one",
      getState: () =>
        herdrConnected
          ? ({ connection: "connected", snapshot, error: null } as const)
          : ({ connection: "connecting", snapshot: null, error: null } as const),
      subscribe: (listener: () => void) => {
        notifyHost = listener;
        return () => {};
      },
      start: () => {},
      dispose: () => {},
      readAgent: async () => ({
        pane_id: "w1:p2",
        workspace_id: "w1",
        tab_id: "w1:t1",
        source: "recent_unwrapped",
        format: "text",
        text: "native agent output",
        revision: 7,
        truncated: false,
      }),
      promptAgent: async () => snapshot.agents[0]!,
      focusAgent: async () => {},
      interruptAgent: async () => {},
      reportThread: async (input) => {
        reports.push(input);
      },
      openThreadTerminal: async (input) => {
        openedTerminals.push(input.terminalId);
        return {
          paneId: "w1:p3",
          index: input.index,
          total: input.total,
          created: false,
        };
      },
      focusThreadTerminalPane: async () => true,
      closeThreadTerminalPane: async () => {},
      openServerPane: async () => {},
    } satisfies HerdrTuiHost;
    const terminalSummary = (terminalId: string) => ({
      threadId: "t1",
      terminalId,
      cwd: "/workspace/project-one",
      worktreePath: null,
      status: "running" as const,
      pid: 123,
      exitCode: null,
      exitSignal: null,
      hasRunningSubprocess: false,
      label: "shell",
      updatedAt: "2026-07-27T00:00:00.000Z",
    });
    const fake = fakeClient({
      detail: thread(),
      terminalMetadata: {
        type: "snapshot",
        terminals: [terminalSummary("term-1"), terminalSummary("term-2")],
      },
    });
    const setup = await testRender(
      <ChatView client={fake.client} host={host} onExit={() => {}} />,
      { width: 110, height: 28 },
    );
    await React.act(async () => {
      await setup.renderOnce();
      fake.connect();
      await setup.renderOnce();
      await setup.flush();
    });
    expect(setup.captureCharFrame()).not.toContain("What should we build");
    await React.act(async () => {
      herdrConnected = true;
      notifyHost();
      await setup.renderOnce();
      await setup.flush();
    });
    const hosted = await setup.waitForFrame((frame) => frame.includes("Ask anything"));
    expect(hosted).not.toContain("Search projects");
    expect(hosted).not.toContain("Reviewer");
    await React.act(async () => {
      setup.mockInput.pressKey("f", { ctrl: true });
      await setup.renderOnce();
    });
    const withT3Sidebar = await setup.waitForFrame((frame) => frame.includes("Search projects"));
    expect(withT3Sidebar).not.toContain("Reviewer");
    await React.act(async () => {
      setup.mockInput.pressKey("f", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => !frame.includes("Search projects"));
    await React.act(async () => {
      setup.mockInput.pressKey("k", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Type a command"));
    await React.act(async () => {
      await setup.mockInput.typeText("T3 sidebar");
      await setup.renderOnce();
    });
    const sidebarCommand = await setup.waitForFrame((frame) => frame.includes("Show T3 sidebar"));
    expect(sidebarCommand).toContain("^F");
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Search projects"));
    await React.act(async () => {
      setup.mockInput.pressKey("f", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => !frame.includes("Search projects"));
    await setup.waitFor(() => reports.some((report) => report?.threadId === "t1"));
    await React.act(async () => {
      setup.mockInput.pressKey("e", { ctrl: true });
      await setup.renderOnce();
    });
    const withTerminal = await setup.waitForFrame((frame) =>
      frame.includes("Terminal · Thread one"),
    );
    expect(withTerminal).toContain("+ new");
    await setup.waitFor(() => openedTerminals.includes("term-1"));
    await React.act(async () => {
      setup.mockInput.pressKey("p", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("^P focus"));
    await React.act(async () => {
      setup.mockInput.pressKey("k", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Type a command"));
    await React.act(async () => {
      await setup.mockInput.typeText("new terminal");
      await setup.renderOnce();
    });
    const terminalCommands = await setup.waitForFrame((frame) => frame.includes("New terminal"));
    expect(terminalCommands).toContain("New terminal");
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitFor(() => openedTerminals.includes("term-3"));
    await React.act(async () => {
      setup.mockInput.pressKey("p", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("^P focus"));
    await React.act(async () => {
      setup.mockInput.pressKey("k", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Type a command"));
    await React.act(async () => {
      await setup.mockInput.typeText("terminal");
      await setup.renderOnce();
    });
    const switchCommands = await setup.waitForFrame((frame) => frame.includes("Next terminal"));
    expect(switchCommands).not.toContain("Herdr terminal");
    setup.renderer.destroy();
  });

  it("Given an unmatched Herdr Space, when its first task is confirmed, then T3 adds the project before creating the thread", async () => {
    const snapshot = {
      version: "0.7.5",
      protocol: 17,
      focused_workspace_id: "w-new",
      workspaces: [
        {
          workspace_id: "w-new",
          number: 1,
          label: "New service",
          focused: true,
          pane_count: 1,
          tab_count: 1,
          active_tab_id: "w-new:t1",
          agent_status: "unknown",
          worktree: {
            repo_key: "new-service",
            repo_name: "new-service",
            repo_root: "/workspace/new-service",
            checkout_path: "/workspace/new-service",
            is_linked_worktree: false,
          },
        },
      ],
      tabs: [],
      panes: [],
      layouts: [],
      agents: [],
    } as const satisfies HerdrSessionSnapshot;
    const host = {
      kind: "herdr",
      workspaceId: "w-new",
      workspaceCwd: "/workspace/new-service",
      getState: () => ({ connection: "connected", snapshot, error: null }) as const,
      subscribe: () => () => {},
      start: () => {},
      dispose: () => {},
      readAgent: async () => {
        throw new Error("no agent");
      },
      promptAgent: async () => {
        throw new Error("no agent");
      },
      focusAgent: async () => {},
      interruptAgent: async () => {},
      reportThread: async () => {},
      openThreadTerminal: async (input) => ({
        paneId: "w-new:p2",
        index: input.index,
        total: input.total,
        created: false,
      }),
      focusThreadTerminalPane: async () => true,
      closeThreadTerminalPane: async () => {},
      openServerPane: async () => {},
    } satisfies HerdrTuiHost;
    const createdProjects: Array<Parameters<TuiClient["createProject"]>[0]> = [];
    const createdThreads: Array<Parameters<TuiClient["createThread"]>[0]> = [];
    const fake = fakeClient({
      detail: thread(),
      shellSnapshot: shell([], []),
      createProject: async (input) => {
        createdProjects.push(input);
        return "p-created" as never;
      },
      createThread: async (input) => {
        createdThreads.push(input);
        return "t-created" as never;
      },
    });
    const setup = await testRender(
      <ChatView client={fake.client} host={host} onExit={() => {}} />,
      { width: 110, height: 28 },
    );
    await React.act(async () => {
      await setup.renderOnce();
      fake.connect();
      await setup.renderOnce();
      await setup.flush();
    });
    await setup.waitForFrame(
      (frame) => frame.includes("What should we build in New service?") && frame.includes("gpt-5"),
    );
    await React.act(async () => {
      await setup.mockInput.typeText("build the API");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("build the API"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Press Enter again to add New"));
    expect(createdProjects).toHaveLength(0);

    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitFor(() => createdThreads.length === 1);
    expect(createdProjects).toEqual([
      {
        title: "New service",
        workspaceRoot: "/workspace/new-service",
        defaultModelSelection: { instanceId: "codex", model: "gpt-5" } as never,
      },
    ]);
    expect(createdThreads[0]).toMatchObject({
      projectId: "p-created",
      projectCwd: "/workspace/new-service",
      firstMessage: "build the API",
      worktreePath: null,
      createWorktree: false,
    });
    setup.renderer.destroy();
  });
});

describe("ChatView source-control panel", () => {
  it("Given a narrow terminal, when the user opens the panel and presses Enter, then it replaces the main pane and runs the selected action", async () => {
    const pulls: string[] = [];
    const vcsStatus = {
      isRepo: true,
      hasPrimaryRemote: true,
      isDefaultRef: false,
      refName: "feature/panel",
      hasWorkingTreeChanges: false,
      workingTree: { files: [], insertions: 0, deletions: 0 },
      hasUpstream: true,
      aheadCount: 0,
      behindCount: 2,
      pr: null,
    } as unknown as VcsStatusResult;
    const fake = fakeClient({
      detail: thread(),
      vcsStatus,
      runGitPull: async (cwd) => {
        pulls.push(cwd);
      },
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 84,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    await React.act(async () => {
      setup.mockInput.pressKey("l", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame(
      (frame) => frame.includes("Source Control") && frame.includes("feature/panel"),
    );
    expect(setup.captureCharFrame()).not.toContain("Type a reply");

    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    expect(pulls).toEqual(["/workspace/project-one"]);
    setup.renderer.destroy();
  });

  it("Given the panel is focused, when the user moves down, then the disabled action reason is shown", async () => {
    const vcsStatus = {
      isRepo: true,
      hasPrimaryRemote: true,
      isDefaultRef: false,
      refName: "feature/panel",
      hasWorkingTreeChanges: false,
      workingTree: { files: [], insertions: 0, deletions: 0 },
      hasUpstream: true,
      aheadCount: 0,
      behindCount: 2,
      pr: null,
    } as unknown as VcsStatusResult;
    const fake = fakeClient({ detail: thread(), vcsStatus });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 112,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    await React.act(async () => {
      setup.mockInput.pressKey("l", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Source Control"));
    await React.act(async () => {
      setup.mockInput.pressArrow("down");
      setup.mockInput.pressArrow("down");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Pull or rebase before"));
    setup.renderer.destroy();
  });
});

describe("ChatView tmux scrolling", () => {
  it("Given an image is visible, when tmux delivers a scroll fallback as an arrow key, then the selected thread does not change", async () => {
    const detail = {
      ...thread(),
      messages: [
        {
          id: "u1",
          role: "user",
          text: "image under review",
          createdAt: "2026-07-13T00:00:00.000Z",
          updatedAt: "2026-07-13T00:00:00.000Z",
          streaming: false,
          attachments: [
            {
              type: "image",
              id: "att1",
              name: "diagram.png",
              mimeType: "image/png",
              sizeBytes: 1024,
            },
          ],
        },
      ],
    } as unknown as OrchestrationThread;
    const fake = fakeClient({
      detail,
      shellSnapshot: shell([
        {
          id: "t1",
          projectId: "p1",
          title: "Thread one",
          updatedAt: "2026-07-13T00:00:01.000Z",
          session: { status: "idle" },
        },
        {
          id: "t2",
          projectId: "p1",
          title: "Thread two",
          updatedAt: "2026-07-13T00:00:00.000Z",
          session: { status: "idle" },
        },
      ] as unknown as OrchestrationShellSnapshot["threads"]),
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    await setup.waitForFrame((frame) => frame.includes("diagram.png"));
    expect(fake.subscribedThreadIds.at(-1)).toBe("t1");

    await React.act(async () => {
      setup.mockInput.pressArrow("down");
      await setup.renderOnce();
    });

    expect(fake.subscribedThreadIds).toEqual(["t1"]);
    setup.renderer.destroy();
  });
});

describe("ChatView image lightbox", () => {
  it("Given a scrolled conversation, when an image is expanded and closed, then the conversation keeps its scroll position", async () => {
    const image = {
      data: new Uint8Array([255, 0, 0, 255]),
      imageWidth: 1,
      imageHeight: 1,
    } satisfies RgbaImage;
    const history = Array.from({ length: 24 }, (_, index) => ({
      id: `history-${index}`,
      role: "assistant",
      text: `history marker ${index}`,
      createdAt: "2026-07-13T00:00:00.000Z",
      updatedAt: "2026-07-13T00:00:00.000Z",
      streaming: false,
      attachments: [],
    }));
    const detail = {
      ...thread(),
      messages: [
        ...history,
        {
          id: "image-message",
          role: "user",
          text: "inspect the image",
          createdAt: "2026-07-13T00:00:00.000Z",
          updatedAt: "2026-07-13T00:00:00.000Z",
          streaming: false,
          attachments: [
            {
              type: "image",
              id: "att1",
              name: "diagram.png",
              mimeType: "image/png",
              sizeBytes: 1024,
            },
          ],
        },
        {
          id: "tail-1",
          role: "assistant",
          text: "tail marker one",
          createdAt: "2026-07-13T00:00:00.000Z",
          updatedAt: "2026-07-13T00:00:00.000Z",
          streaming: false,
          attachments: [],
        },
        {
          id: "tail-2",
          role: "assistant",
          text: "tail marker two",
          createdAt: "2026-07-13T00:00:00.000Z",
          updatedAt: "2026-07-13T00:00:00.000Z",
          streaming: false,
          attachments: [],
        },
      ],
    } as unknown as OrchestrationThread;
    const fake = fakeClient({
      detail,
      getAttachmentUrl: async () => "https://img.test/1",
      getAttachmentImage: async () => image,
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });
    const manager = installKittyImageExtension(setup.renderer, {
      writer: { write: () => {} },
    });
    const capabilities = setRendererCapabilities(setup.renderer, { kitty_graphics: true });
    setup.renderer.emit(CliRenderEvents.CAPABILITIES, capabilities);

    await selectThread(setup, fake.connect);
    for (let index = 0; index < 8; index += 1) {
      await setup.renderOnce();
      await setup.flush();
    }
    const initialFrame = await setup.waitForFrame((frame) => frame.includes("diagram.png"));
    const initialDiagramRow = initialFrame
      .split("\n")
      .findIndex((line) => line.includes("diagram.png"));
    expect(initialDiagramRow).toBeGreaterThanOrEqual(0);

    await setup.mockMouse.scroll(40, initialDiagramRow, "up");
    await setup.renderOnce();
    manager.resumeAfterScroll();
    for (let index = 0; index < 8; index += 1) {
      await setup.renderOnce();
      await setup.flush();
    }
    const before = await setup.waitForFrame((frame) => frame.includes("diagram.png"));
    expect(before).not.toBe(initialFrame);
    const beforeScrollTop = findScrollBox(setup.renderer.root)?.scrollTop;
    expect(beforeScrollTop).toBeGreaterThan(0);
    const diagramRow = before.split("\n").findIndex((line) => line.includes("diagram.png"));
    const diagramColumn = (before.split("\n")[diagramRow] ?? "").indexOf("diagram.png");
    expect(diagramRow).toBeGreaterThanOrEqual(0);
    expect(diagramColumn).toBeGreaterThanOrEqual(0);

    await React.act(async () => {
      await setup.mockMouse.click(diagramColumn - 2, diagramRow + 1);
      await setup.flush();
    });
    await setup.waitForFrame((frame) => frame.includes("Esc / click to close"));

    await React.act(async () => {
      await setup.mockMouse.click(40, 3);
      await setup.flush();
    });
    await setup.waitFor(() => findScrollBox(setup.renderer.root)?.scrollTop === beforeScrollTop);
    const afterScrollTop = findScrollBox(setup.renderer.root)?.scrollTop;

    expect(afterScrollTop).toBe(beforeScrollTop);
    setup.renderer.destroy();
  });
});

describe("ChatView acknowledged submissions", () => {
  it("Given a thread is in Build mode, when Build is clicked, then it persists Plan mode", async () => {
    const interactionModes: string[] = [];
    const persistence = deferred<void>();
    const fake = fakeClient({
      detail: thread(),
      setInteractionMode: (_threadId, mode) => {
        interactionModes.push(mode);
        return persistence.promise;
      },
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    const frame = await setup.waitForFrame((current) => current.includes("^B Build"));
    const lines = frame.split("\n");
    const row = lines.findIndex((line) => line.includes("^B Build"));
    const col = (lines[row] ?? "").indexOf("Build");
    await React.act(async () => {
      await setup.mockMouse.click(col, row);
      await setup.flush();
    });

    expect(interactionModes).toEqual(["plan"]);
    expect(await setup.waitForFrame((current) => current.includes("^B Plan"))).toContain("^B Plan");
    persistence.resolve();
    setup.renderer.destroy();
  });

  it("Given a Plan mode change fails, then the composer returns to Build and shows the error", async () => {
    const persistence = deferred<void>();
    const fake = fakeClient({
      detail: thread(),
      setInteractionMode: () => persistence.promise,
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    const frame = await setup.waitForFrame((current) => current.includes("^B Build"));
    const lines = frame.split("\n");
    const row = lines.findIndex((line) => line.includes("^B Build"));
    const col = (lines[row] ?? "").indexOf("Build");
    await React.act(async () => {
      await setup.mockMouse.click(col, row);
      await setup.flush();
    });
    await setup.waitForFrame((current) => current.includes("^B Plan"));
    await React.act(async () => {
      persistence.reject(new Error("not supported"));
      await setup.flush();
    });

    const rolledBack = await setup.waitForFrame(
      (current) => current.includes("^B Build") && current.includes("mode change failed"),
    );
    expect(rolledBack).toContain("mode change failed");
    setup.renderer.destroy();
  });

  it("Given the terminal takes focus, then the static prompt preserves its rows without leaving a bottom gap", async () => {
    const fake = fakeClient({ detail: thread() });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    await React.act(async () => {
      setup.mockInput.pressKey("e", { ctrl: true });
      await setup.renderOnce();
    });
    const frame = await setup.waitForFrame((current) => current.includes("Terminal · Thread one"));
    const lines = frame.split("\n");
    const promptRow = lines.findIndex((line) => line.includes("^P prompt"));
    const terminalRow = lines.findIndex((line) => line.includes("Terminal · Thread one"));
    const footerRow = lines.findIndex(
      (line, index) => index > terminalRow && line.includes("^E close term"),
    );
    expect(promptRow).toBeGreaterThanOrEqual(0);
    expect(terminalRow).toBeGreaterThan(promptRow);
    expect(footerRow).toBe(27);
    setup.renderer.destroy();
  });

  it("Given a terminal tab is selected, when clear and restart run from the command palette, then both target that exact session", async () => {
    const clearCalls: Array<Parameters<TuiClient["terminalClear"]>> = [];
    const restartCalls: Array<Parameters<TuiClient["terminalRestart"]>[0]> = [];
    const fake = fakeClient({
      detail: thread(),
      terminalClear: async (...args) => {
        clearCalls.push(args);
      },
      terminalRestart: async (input) => {
        restartCalls.push(input);
      },
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    await React.act(async () => {
      setup.mockInput.pressKey("e", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Terminal · Thread one"));
    await React.act(async () => {
      setup.mockInput.pressKey("p", { ctrl: true });
      await setup.renderOnce();
    });
    await React.act(async () => {
      setup.mockInput.pressKey("k", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Type a command"));
    await React.act(async () => {
      await setup.mockInput.typeText("clear terminal");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Clear terminal"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitFor(() => clearCalls.length === 1);

    await React.act(async () => {
      setup.mockInput.pressKey("k", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Type a command"));
    await React.act(async () => {
      await setup.mockInput.typeText("restart terminal");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Restart terminal"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitFor(() => restartCalls.length === 1);

    const [threadId, terminalId] = clearCalls[0] ?? [];
    const restart = restartCalls[0];
    expect(String(threadId)).toBe("t1");
    expect(typeof terminalId).toBe("string");
    expect(terminalId?.length).toBeGreaterThan(0);
    expect(restart?.threadId).toBe(threadId);
    expect(restart?.terminalId).toBe(terminalId);
    expect(restart?.cwd).toBe("/workspace/project-one");
    expect(restart?.worktreePath).toBeNull();
    // The web-like full-height sidebar owns its column, so the terminal is
    // correctly sized to the remaining main surface rather than the whole app.
    expect(restart?.cols).toBe(72);
    expect(restart?.rows).toBe(7);
    setup.renderer.destroy();
  });

  it("Given model, effort, and Plan mode are changed, when the next reply is sent, then the complete selection is dispatched", async () => {
    const calls: Array<Parameters<TuiClient["sendReply"]>> = [];
    const fake = fakeClient({
      detail: thread(),
      listModels: async () =>
        [
          {
            instanceId: "codex",
            model: "gpt-5",
            label: "GPT-5",
            providerLabel: "Codex",
            capabilities: null,
          },
          {
            instanceId: "codex",
            model: "gpt-5.1",
            label: "GPT-5.1",
            providerLabel: "Codex",
            capabilities: {
              optionDescriptors: [
                {
                  type: "select",
                  id: "reasoningEffort",
                  label: "Effort",
                  options: [
                    { id: "low", label: "Low", isDefault: true },
                    { id: "high", label: "High" },
                  ],
                },
                {
                  type: "boolean",
                  id: "fastMode",
                  label: "Fast mode",
                  currentValue: true,
                },
              ],
            },
          },
        ] as never,
      sendReply: async (...args) => {
        calls.push(args);
      },
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    await React.act(async () => {
      setup.mockInput.pressKey("k", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Type a command"));
    await React.act(async () => {
      await setup.mockInput.typeText("model");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Change model"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("GPT-5.1"));
    await React.act(async () => {
      setup.mockInput.pressArrow("down");
      await setup.renderOnce();
    });
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("model gpt-5.1"));
    await React.act(async () => {
      setup.mockInput.pressKey("k", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Type a command"));
    await React.act(async () => {
      await setup.mockInput.typeText("effort");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Change reasoning effort"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("effort ▸") && frame.includes("High"));
    await React.act(async () => {
      setup.mockInput.pressArrow("down");
      await setup.renderOnce();
    });
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("effort high"));
    await React.act(async () => {
      setup.mockInput.pressKey("b", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("^B Plan"));
    await React.act(async () => {
      await setup.mockInput.typeText("use the selected model");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("use the selected model"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitFor(() => calls.length === 1);

    expect(calls[0]?.[3]).toEqual({
      instanceId: "codex",
      model: "gpt-5.1",
      options: [
        { id: "fastMode", value: true },
        { id: "reasoningEffort", value: "high" },
      ],
    } as never);
    expect(calls[0]?.[0].interactionMode).toBe("plan");
    setup.renderer.destroy();
  });

  it("Given the clipboard contains a supported image, when it is pasted into the prompt and sent, then the bounded attachment is dispatched with the draft", async () => {
    const calls: Array<Parameters<TuiClient["sendReply"]>> = [];
    const fake = fakeClient({
      detail: thread(),
      sendReply: async (...args) => {
        calls.push(args);
      },
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    await React.act(async () => {
      await setup.mockInput.typeText("explain this screenshot");
      setup.renderer.keyInput.processPaste(Uint8Array.from(Buffer.from(PNG_BASE64, "base64")), {
        kind: "binary",
        mimeType: "image/png",
      });
      await setup.renderOnce();
    });
    await setup.waitForFrame(
      (frame) => frame.includes("explain this screenshot") && frame.includes("clipboard-i"),
    );
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitFor(() => calls.length === 1);

    expect(calls[0]?.[1]).toBe("explain this screenshot");
    expect(calls[0]?.[2]).toEqual([
      {
        type: "image",
        name: "clipboard-image-1.png",
        mimeType: "image/png",
        sizeBytes: 68,
        dataUrl: `data:image/png;base64,${PNG_BASE64}`,
      },
    ]);
    setup.renderer.destroy();
  });

  it("Given a reply is in flight, when Enter repeats and the request fails, then one request is made and the exact draft remains", async () => {
    const request = deferred<void>();
    const calls: Array<{ readonly text: string }> = [];
    const fake = fakeClient({
      detail: thread(),
      sendReply: async (_detail, text) => {
        calls.push({ text });
        return request.promise;
      },
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    await React.act(async () => {
      await setup.mockInput.typeText("keep this exact draft");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("keep this exact draft"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitFor(() => calls.length > 0);

    expect(calls).toEqual([{ text: "keep this exact draft" }]);
    await React.act(async () => {
      request.reject(new Error("offline"));
      await Promise.resolve();
    });
    const frame = await setup.waitForFrame((next) => next.includes("send failed"));
    expect(frame).toContain("keep this exact draft");
    setup.renderer.destroy();
  });

  it("Given a reply is accepted, when acknowledgement arrives, then the draft clears only after success", async () => {
    const request = deferred<void>();
    const fake = fakeClient({
      detail: thread(),
      sendReply: () => request.promise,
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    await React.act(async () => {
      await setup.mockInput.typeText("ship after ack");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("ship after ack"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    const pendingFrame = await setup.waitForFrame((next) => next.includes("Sending"));
    expect(pendingFrame).toContain("ship after ack");

    await React.act(async () => {
      request.resolve();
      await Promise.resolve();
    });
    const successFrame = await setup.waitForFrame(
      (next) => next.includes("✓ Reply") && !next.includes("ship after ack"),
    );
    expect(successFrame).not.toContain("ship after ack");
    setup.renderer.destroy();
  });

  it("Given a custom user-input answer is in flight, when Enter repeats and the request fails, then one response is made and the answer remains", async () => {
    const request = deferred<void>();
    const answers: Array<Record<string, string | string[]>> = [];
    const pendingActivity = {
      id: "activity-1",
      kind: "user-input.requested",
      createdAt: "2026-07-13T00:00:00.000Z",
      turnId: null,
      summary: "Input requested",
      tone: "info",
      payload: {
        requestId: "request-1",
        questions: [
          {
            id: "scope",
            header: "Scope",
            question: "Which scope?",
            options: [{ label: "Everything", description: "" }],
            multiSelect: false,
          },
        ],
      },
    } as unknown as OrchestrationThread["activities"][number];
    const fake = fakeClient({
      detail: thread([pendingActivity]),
      respondUserInput: async (_threadId, _requestId, nextAnswers) => {
        answers.push(nextAnswers);
        return request.promise;
      },
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    await setup.waitForFrame((frame) => frame.includes("Which scope?"));
    await React.act(async () => {
      await setup.mockInput.typeText("Only the terminal UI");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Only the terminal UI"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitFor(() => answers.length > 0);

    expect(answers).toEqual([{ scope: "Only the terminal UI" }]);
    await React.act(async () => {
      request.reject(new Error("disconnected"));
      await Promise.resolve();
    });
    const frame = await setup.waitForFrame((next) => next.includes("answer failed"));
    expect(frame).toContain("Only the terminal UI");
    setup.renderer.destroy();
  });
});

describe("ChatView new-thread parity", () => {
  it("Given a local new-thread draft, when Enter repeats and creation fails, then the shared prompt keeps one request and preserves the task", async () => {
    const request = deferred<Awaited<ReturnType<TuiClient["createThread"]>>>();
    const calls: Array<Parameters<TuiClient["createThread"]>[0]> = [];
    const fake = fakeClient({
      detail: thread(),
      listModels: async () =>
        [
          {
            instanceId: "codex",
            model: "gpt-5",
            label: "GPT-5",
            providerLabel: "Codex",
            capabilities: {
              optionDescriptors: [
                {
                  type: "select",
                  id: "reasoningEffort",
                  label: "Effort",
                  options: [{ id: "medium", label: "Medium", isDefault: true }],
                },
              ],
            },
          },
        ] as never,
      createThread: async (input) => {
        calls.push(input);
        return request.promise;
      },
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    await React.act(async () => {
      setup.mockInput.pressKey("n", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame(
      (frame) =>
        frame.includes("What should we build in Project one?") &&
        frame.includes("effort medium") &&
        frame.includes("▸ Send"),
    );
    expect(setup.captureCharFrame()).not.toContain("new thread");
    await React.act(async () => {
      await setup.mockInput.typeText("preserve this new task");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("preserve this new task"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitFor(() => calls.length > 0);

    expect(calls).toHaveLength(1);
    expect(calls[0]?.modelSelection.options).toEqual([{ id: "reasoningEffort", value: "medium" }]);
    expect(calls[0]?.attachments).toEqual([]);
    await React.act(async () => {
      request.reject(new Error("offline"));
      await Promise.resolve();
    });
    const frame = await setup.waitForFrame((next) => next.includes("create failed"));
    expect(frame).not.toContain("new thread");
    expect(frame).toContain("preserve this new task");
    setup.renderer.destroy();
  });

  it("Given an empty task, when Enter is pressed, then the local draft stays in the shared prompt", async () => {
    let calls = 0;
    const fake = fakeClient({
      detail: thread(),
      createThread: async () => {
        calls += 1;
        return "t-new" as never;
      },
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    await React.act(async () => {
      setup.mockInput.pressKey("n", { ctrl: true });
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    const frame = await setup.waitForFrame((next) =>
      next.includes("What should we build in Project one?"),
    );
    expect(frame).toContain("▸ Send");
    expect(frame).not.toContain("new thread");
    expect(calls).toBe(0);
    setup.renderer.destroy();
  });

  it("Given a thread is active, when its new-thread draft is sent, then the inherited checkout is used and the returned thread is selected", async () => {
    const calls: Array<Parameters<TuiClient["createThread"]>[0]> = [];
    const fake = fakeClient({
      detail: thread(),
      createThread: async (input) => {
        calls.push(input);
        return "t-created" as never;
      },
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 28,
    });

    await selectThread(setup, fake.connect);
    await React.act(async () => {
      setup.mockInput.pressKey("n", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame(
      (frame) =>
        frame.includes("What should we build in Project one?") &&
        frame.includes("main") &&
        frame.includes("^B Build"),
    );
    await React.act(async () => {
      setup.mockInput.pressKey("\t", { shift: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("^B Plan"));
    await React.act(async () => {
      await setup.mockInput.typeText("create in isolation");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("create in isolation"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
      await Promise.resolve();
    });
    await setup.waitFor(() => calls.length === 1);
    await setup.waitFor(() => fake.subscribedThreadIds.at(-1) === "t-created");
    const frame = setup.captureCharFrame();

    expect(calls[0]).toMatchObject({
      projectCwd: "/workspace/project-one",
      firstMessage: "create in isolation",
      branch: "main",
      worktreePath: null,
      createWorktree: false,
      interactionMode: "plan",
    });
    expect(fake.subscribedThreadIds.at(-1)).toBe("t-created");
    expect(frame).not.toContain("new thread");
    expect(frame).not.toContain("create in isolation");
    setup.renderer.destroy();
  });

  it("Given a project header is selected, when the shell loads, then its new-thread composer opens automatically", async () => {
    const calls: Array<Parameters<TuiClient["createThread"]>[0]> = [];
    const fake = fakeClient({
      detail: thread(),
      shellSnapshot: shell([], [projectTwo] as never),
      listRefs: async () =>
        ({
          refs: [
            {
              name: "develop",
              current: true,
              isDefault: true,
              worktreePath: "/workspace/project-two",
            },
          ],
          isRepo: true,
          hasPrimaryRemote: true,
          nextCursor: null,
          totalCount: 1,
        }) as never,
      createThread: async (input) => {
        calls.push(input);
        return "t-project-two" as never;
      },
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 32,
    });

    await React.act(async () => {
      await setup.renderOnce();
      fake.connect();
      await setup.renderOnce();
      await setup.flush();
    });
    await setup.waitForFrame((frame) => frame.includes("Project two"));
    await setup.waitForFrame(
      (frame) =>
        frame.includes("What should we build in Project two?") &&
        frame.includes("branch develop ▾"),
    );
    await React.act(async () => {
      await setup.mockInput.typeText("build in the selected project");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("build in the selected project"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
      await Promise.resolve();
    });
    await setup.waitFor(() => calls.length === 1);

    expect(calls[0]).toMatchObject({
      projectId: "p2",
      projectCwd: "/workspace/project-two",
      branch: "develop",
      firstMessage: "build in the selected project",
      modelSelection: { instanceId: "codex", model: "gpt-5-mini" },
    });
    setup.renderer.destroy();
  });

  it("Given a new-thread draft, when the user chooses a new worktree and another base branch, then first send creates it from that branch", async () => {
    const calls: Array<Parameters<TuiClient["createThread"]>[0]> = [];
    const fake = fakeClient({
      detail: thread(),
      listRefs: async () =>
        ({
          refs: [
            {
              name: "main",
              current: true,
              isDefault: true,
              worktreePath: "/workspace/project-one",
            },
            {
              name: "feature/worktree-base",
              current: false,
              isDefault: false,
              worktreePath: null,
            },
          ],
          isRepo: true,
          hasPrimaryRemote: true,
          nextCursor: null,
          totalCount: 2,
        }) as never,
      createThread: async (input) => {
        calls.push(input);
        return "t-worktree" as never;
      },
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 32,
    });

    await selectThread(setup, fake.connect);
    await React.act(async () => {
      setup.mockInput.pressKey("n", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame(
      (frame) => frame.includes("Project workspace ▾") && frame.includes("branch main ▾"),
    );

    await React.act(async () => {
      setup.mockInput.pressKey("k", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Type a command"));
    await React.act(async () => {
      await setup.mockInput.typeText("workspace");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Change workspace"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("workspace ▸"));
    await React.act(async () => {
      setup.mockInput.pressArrow("down");
      await setup.renderOnce();
    });
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("New worktree ▾"));

    await React.act(async () => {
      setup.mockInput.pressKey("k", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Type a command"));
    await React.act(async () => {
      await setup.mockInput.typeText("base branch");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Change base branch"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("base branch ▸"));
    await React.act(async () => {
      setup.mockInput.pressArrow("down");
      await setup.renderOnce();
    });
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("branch feature/worktree-base ▾"));
    await React.act(async () => {
      await setup.mockInput.typeText("create isolated work");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("create isolated work"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
      await Promise.resolve();
    });
    await setup.waitFor(() => calls.length === 1);

    expect(calls[0]).toMatchObject({
      branch: "feature/worktree-base",
      worktreePath: null,
      createWorktree: true,
      firstMessage: "create isolated work",
    });
    setup.renderer.destroy();
  });

  it("Given a new-thread draft uses the current checkout, when another branch is selected, then the checkout switches before first send", async () => {
    const switched: Array<{ cwd: string; refName: string }> = [];
    const calls: Array<Parameters<TuiClient["createThread"]>[0]> = [];
    const fake = fakeClient({
      detail: thread(),
      listRefs: async () =>
        ({
          refs: [
            {
              name: "main",
              current: true,
              isDefault: true,
              worktreePath: "/workspace/project-one",
            },
            {
              name: "feature/current-checkout",
              current: false,
              isDefault: false,
              worktreePath: null,
            },
          ],
          isRepo: true,
          hasPrimaryRemote: true,
          nextCursor: null,
          totalCount: 2,
        }) as never,
      switchRef: async (cwd, refName) => {
        switched.push({ cwd, refName });
        return { refName } as never;
      },
      createThread: async (input) => {
        calls.push(input);
        return "t-branch" as never;
      },
    });
    const setup = await testRender(<ChatView client={fake.client} onExit={() => {}} />, {
      width: 110,
      height: 32,
    });

    await selectThread(setup, fake.connect);
    await React.act(async () => {
      setup.mockInput.pressKey("n", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("branch main ▾"));
    await React.act(async () => {
      setup.mockInput.pressKey("k", { ctrl: true });
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Type a command"));
    await React.act(async () => {
      await setup.mockInput.typeText("change branch");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("Change branch"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("branch ▸"));
    await React.act(async () => {
      setup.mockInput.pressArrow("down");
      await setup.renderOnce();
    });
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
      await Promise.resolve();
    });
    await setup.waitFor(() => switched.length === 1);
    await setup.waitForFrame((frame) => frame.includes("branch feature/current-checkout ▾"));
    await React.act(async () => {
      await setup.mockInput.typeText("use selected checkout");
      await setup.renderOnce();
    });
    await setup.waitForFrame((frame) => frame.includes("use selected checkout"));
    await React.act(async () => {
      setup.mockInput.pressEnter();
      await setup.renderOnce();
      await Promise.resolve();
    });
    await setup.waitFor(() => calls.length === 1);

    expect(switched).toEqual([
      { cwd: "/workspace/project-one", refName: "feature/current-checkout" },
    ]);
    expect(calls[0]).toMatchObject({
      branch: "feature/current-checkout",
      worktreePath: null,
      createWorktree: false,
    });
    setup.renderer.destroy();
  });
});
