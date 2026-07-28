import type { BoxRenderable, MouseEvent as TuiMouseEvent } from "@opentui/core";
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
  const dockRef = React.useRef<BoxRenderable | null>(null);
  const compact = width < 90;
  const terminalLabels = tabIds.map((_, index) =>
    compact ? `T${index + 1}` : `Terminal ${index + 1}`,
  );
  const tabsWidth =
    terminalLabels.reduce((total, label, index) => {
      const closeWidth = tabIds[index] === activeTabId && tabIds.length > 1 ? 2 : 0;
      return total + label.length + closeWidth + 4;
    }, 0) + (compact ? 5 : 7);
  const titleWidth = Math.max(1, width - tabsWidth - 6);
  const handleDockMouseDown = React.useCallback(
    (event: TuiMouseEvent) => {
      const dock = dockRef.current;
      if (!dock || event.target !== dock) return;
      const localX = event.x - dock.screenX;
      let cursor = width - tabsWidth - 2;
      for (let index = 0; index < tabIds.length; index += 1) {
        const id = tabIds[index] as string;
        const active = id === activeTabId;
        const label = terminalLabels[index] as string;
        const closeWidth = active && tabIds.length > 1 ? 2 : 0;
        const tabWidth = label.length + 2 + (active ? 2 : 0) + closeWidth;
        cursor += 1;
        if (localX >= cursor && localX < cursor + tabWidth) {
          if (closeWidth > 0 && localX >= cursor + tabWidth - closeWidth) onCloseTab(id);
          else onSelectTab(id);
          return;
        }
        cursor += tabWidth;
      }
      cursor += 1;
      if (localX >= cursor && localX < cursor + (compact ? 2 : 6)) onNewTab();
    },
    [
      activeTabId,
      compact,
      onCloseTab,
      onNewTab,
      onSelectTab,
      tabIds,
      tabsWidth,
      terminalLabels,
      width,
    ],
  );
  return (
    <box
      ref={dockRef}
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
      onMouseDown={handleDockMouseDown}
    >
      <box flexDirection="row" width={titleWidth} flexShrink={0} overflow="hidden">
        <text fg={palette.dim}>{clip(title, titleWidth)}</text>
      </box>
      <box flexDirection="row" flexShrink={0} width={tabsWidth}>
        {tabIds.map((id, index) => {
          const active = id === activeTabId;
          const label = terminalLabels[index] as string;
          const tabWidth =
            label.length + 2 + (active ? 2 : 0) + (active && tabIds.length > 1 ? 2 : 0);
          return (
            <box
              key={id}
              flexDirection="row"
              marginLeft={1}
              paddingLeft={1}
              paddingRight={1}
              width={tabWidth}
              height={1}
              flexShrink={0}
              onMouseDown={() => onSelectTab(id)}
              {...(active ? { backgroundColor: palette.selectedBg } : {})}
            >
              <text fg={active ? palette.accent : palette.dim}>
                {active ? (
                  <>
                    <span fg={palette.accent}>{"▸ "}</span>
                    <strong>{label}</strong>
                  </>
                ) : (
                  label
                )}
              </text>
              {active && tabIds.length > 1 ? (
                <text fg={palette.dim} onMouseDown={() => onCloseTab(id)}>
                  {" ×"}
                </text>
              ) : null}
            </box>
          );
        })}
        <box
          marginLeft={1}
          paddingLeft={1}
          width={compact ? 2 : 6}
          height={1}
          flexShrink={0}
          onMouseDown={onNewTab}
        >
          <text fg={palette.accent}>{compact ? "+" : "+ New"}</text>
        </box>
      </box>
    </box>
  );
});
