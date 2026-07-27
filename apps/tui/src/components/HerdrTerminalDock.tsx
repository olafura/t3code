import * as React from "react";

import { clip } from "../format.ts";
import { usePalette } from "../theme.ts";

export const HerdrTerminalDock = React.memo(function HerdrTerminalDock({
  title,
  width,
  tabIds,
  activeTabId,
  onSelectTab,
  onNewTab,
  onCloseTab,
}: {
  readonly title: string;
  readonly width: number;
  readonly tabIds: ReadonlyArray<string>;
  readonly activeTabId: string;
  readonly onSelectTab: (id: string) => void;
  readonly onNewTab: () => void;
  readonly onCloseTab: (id: string) => void;
}): React.ReactNode {
  const palette = usePalette();
  return (
    <box
      flexDirection="row"
      height={3}
      flexShrink={0}
      border
      borderStyle="single"
      borderColor={palette.dim}
      paddingLeft={1}
      paddingRight={1}
      overflow="hidden"
      justifyContent="space-between"
    >
      <box flexDirection="row" flexShrink={1} overflow="hidden">
        <text fg={palette.dim}>{clip(`Terminal · ${title}`, Math.max(1, width - 34))}</text>
      </box>
      <box flexDirection="row" flexShrink={0}>
        {tabIds.map((id, index) => {
          const active = id === activeTabId;
          return (
            <box key={id} flexDirection="row" marginLeft={1}>
              <box onMouseDown={() => onSelectTab(id)}>
                <text fg={active ? palette.accent : palette.dim}>
                  {`${active ? "▸" : ""}${index + 1}`}
                </text>
              </box>
              {active && tabIds.length > 1 ? (
                <box onMouseDown={() => onCloseTab(id)}>
                  <text fg={palette.dim}>{" ×"}</text>
                </box>
              ) : null}
            </box>
          );
        })}
        <box marginLeft={1} onMouseDown={onNewTab}>
          <text fg={palette.dim}>+ new</text>
        </box>
        <text fg={palette.dim}>{" · ^P from terminal"}</text>
      </box>
    </box>
  );
});
