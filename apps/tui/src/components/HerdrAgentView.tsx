import type { ScrollBoxRenderable } from "@opentui/core";
import * as React from "react";

import type { HerdrAgentInfo, HerdrPaneReadResult } from "../herdr/protocol.ts";
import { clip } from "../format.ts";
import { usePalette } from "../theme.ts";

export type HerdrAgentReadState =
  | { readonly status: "loading"; readonly read: HerdrPaneReadResult | null }
  | { readonly status: "ready"; readonly read: HerdrPaneReadResult }
  | { readonly status: "error"; readonly read: HerdrPaneReadResult | null };

function agentLabel(agent: HerdrAgentInfo): string {
  return (
    agent.name ??
    agent.display_agent ??
    agent.title ??
    agent.terminal_title_stripped ??
    agent.agent ??
    "Herdr agent"
  );
}

function keyedLines(text: string): ReadonlyArray<{ readonly key: string; readonly line: string }> {
  const seen = new Map<string, number>();
  return text.split(/\r?\n/).map((line) => {
    const occurrence = seen.get(line) ?? 0;
    seen.set(line, occurrence + 1);
    return { key: `${line}\u0000${occurrence}`, line };
  });
}

export const HerdrAgentView = React.memo(function HerdrAgentView({
  agent,
  readState,
  width,
  height,
  scrollRef,
  onFocus,
}: {
  readonly agent: HerdrAgentInfo;
  readonly readState: HerdrAgentReadState;
  readonly width: number;
  readonly height: number;
  readonly scrollRef: React.RefObject<ScrollBoxRenderable | null>;
  readonly onFocus: () => void;
}): React.ReactNode {
  const palette = usePalette();
  const cwd = agent.foreground_cwd ?? agent.cwd ?? "";
  const session = agent.agent_session?.value ?? "";
  const text = readState.read?.text ?? "";
  const hasContext = cwd.length > 0 || session.length > 0;
  const bodyHeight = Math.max(1, height - (hasContext ? 2 : 1));
  return (
    <box flexDirection="column" width={width} height={height} overflow="hidden">
      <box
        flexDirection="row"
        justifyContent="space-between"
        paddingLeft={1}
        paddingRight={1}
        flexShrink={0}
      >
        <text>
          <strong>{clip(agentLabel(agent), Math.max(1, width - 24))}</strong>
          <span fg={palette.dim}>{` · Herdr · ${agent.agent_status}`}</span>
        </text>
        <text onMouseDown={onFocus}>
          <span fg={palette.accent}>focus terminal ↗</span>
        </text>
      </box>
      {hasContext ? (
        <box paddingLeft={1} paddingRight={1} flexShrink={0}>
          <text fg={palette.dim}>
            {clip([cwd, session].filter(Boolean).join(" · "), Math.max(1, width - 2))}
          </text>
        </box>
      ) : null}
      <scrollbox
        ref={scrollRef}
        height={bodyHeight}
        width={width}
        scrollX={false}
        stickyScroll
        stickyStart="bottom"
        paddingLeft={1}
        paddingRight={1}
        style={{
          rootOptions: { backgroundColor: "transparent" },
          contentOptions: { width: "100%", maxWidth: "100%", overflow: "hidden" },
        }}
      >
        {text.length > 0 ? (
          keyedLines(text).map(({ key, line }) => <text key={key}>{line}</text>)
        ) : (
          <text fg={palette.dim}>
            {readState.status === "error"
              ? "Could not read this Herdr agent."
              : "Waiting for agent output…"}
          </text>
        )}
      </scrollbox>
    </box>
  );
});
