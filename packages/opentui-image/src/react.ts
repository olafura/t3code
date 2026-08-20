import { NativeImage } from "@opentui/core";
import {
  useRenderer,
  useTerminalDimensions,
  type ImageProps as NativeImageProps,
} from "@opentui/react";
import type * as React from "react";
import * as ReactRuntime from "react";

const DEFAULT_CELL_WIDTH = 18;
const DEFAULT_CELL_HEIGHT = 35;

export interface ImageProps extends Omit<NativeImageProps, "fit" | "height" | "source" | "width"> {
  readonly data: Uint8Array;
  readonly imageWidth: number;
  readonly imageHeight: number;
  readonly columns?: number;
  readonly rows?: number;
  readonly fallbackCellWidth?: number;
  readonly fallbackCellHeight?: number;
}

export function Image(props: ImageProps): React.ReactElement {
  const {
    data,
    imageWidth,
    imageHeight,
    columns,
    rows,
    fallbackCellWidth = DEFAULT_CELL_WIDTH,
    fallbackCellHeight = DEFAULT_CELL_HEIGHT,
    ...imageProps
  } = props;
  const renderer = useRenderer();
  useTerminalDimensions();
  const source = ReactRuntime.useMemo(
    () => NativeImage.fromRgba(data, imageWidth, imageHeight),
    [data, imageHeight, imageWidth],
  );
  ReactRuntime.useEffect(() => () => source.dispose(), [source]);
  const size = resolveCellSize({
    imageWidth,
    imageHeight,
    ...(columns === undefined ? {} : { columns }),
    ...(rows === undefined ? {} : { rows }),
    cellWidth: renderer.resolution ? renderer.resolution.width / renderer.width : fallbackCellWidth,
    cellHeight: renderer.resolution
      ? renderer.resolution.height / renderer.height
      : fallbackCellHeight,
  });

  return ReactRuntime.createElement("image", {
    ...imageProps,
    source,
    width: size.columns,
    height: size.rows,
    fit: "fill",
  });
}

function resolveCellSize(input: {
  readonly imageWidth: number;
  readonly imageHeight: number;
  readonly columns?: number;
  readonly rows?: number;
  readonly cellWidth: number;
  readonly cellHeight: number;
}): { readonly columns: number; readonly rows: number } {
  const naturalColumns = Math.max(1, Math.ceil(input.imageWidth / input.cellWidth));
  const naturalRows = Math.max(1, Math.ceil(input.imageHeight / input.cellHeight));
  if (input.columns !== undefined && input.rows === undefined) {
    return {
      columns: input.columns,
      rows: Math.max(
        1,
        Math.round(
          (input.imageHeight / input.imageWidth) *
            input.columns *
            (input.cellWidth / input.cellHeight),
        ),
      ),
    };
  }
  if (input.rows !== undefined && input.columns === undefined) {
    return {
      columns: Math.max(
        1,
        Math.round(
          (input.imageWidth / input.imageHeight) *
            input.rows *
            (input.cellHeight / input.cellWidth),
        ),
      ),
      rows: input.rows,
    };
  }
  return {
    columns: input.columns ?? naturalColumns,
    rows: input.rows ?? naturalRows,
  };
}

export * from "./index.ts";
