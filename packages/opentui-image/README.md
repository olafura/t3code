# `@t3tools/opentui-image`

T3 Code's small adapter around OpenTUI's native image support.

OpenTUI owns image layout, clipping, and terminal output. The React wrapper in
this package accepts the existing RGBA preview shape and passes a `NativeImage`
to OpenTUI's built-in `<image>` element. OpenTUI selects Kitty, Sixel, or its
terminal-cell fallback.

The package also keeps two T3-specific pieces:

- bounded Sharp decoding for formats accepted by chat attachments;
- Kitty clipboard reads, including tmux passthrough for remote sessions.

```tsx
import { Image } from "@t3tools/opentui-image/react";

<Image data={rgba} imageWidth={320} imageHeight={180} columns={40} />;
```
