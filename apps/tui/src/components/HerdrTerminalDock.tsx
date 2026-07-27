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
        <text fg={palette.dim}>{clip(title, titleWidth)}</text>
      </box>
      <box flexDirection="row" flexShrink={0}>
        {tabIds.map((id, index) => {
          const active = id === activeTabId;
          const label = terminalLabels[index] as string;
          return (
            <box
              key={id}
              flexDirection="row"
              marginLeft={1}
              paddingLeft={1}
              paddingRight={1}
              {...(active ? { backgroundColor: palette.selectedBg } : {})}
            >
              <box onMouseDown={() => onSelectTab(id)}>
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
              </box>
              {active && tabIds.length > 1 ? (
                <box onMouseDown={() => onCloseTab(id)}>
                  <text fg={palette.dim}>{" ×"}</text>
                </box>
              ) : null}
            </box>
          );
        })}
        <box marginLeft={1} paddingLeft={1} onMouseDown={onNewTab}>
          <text fg={palette.accent}>{compact ? "+" : "+ New"}</text>
        </box>
      </box>
    </box>
  );
});
