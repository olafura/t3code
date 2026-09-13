# Shell examples

Each folder is a complete rice: a `shell.qml` layout composed from the
`T3.Bricks` module and a `theme.json` in the web app's theme format (plus the
shell-only `window`, `radius` and `fonts` keys). Copy one into your config dir
and the app reloads on save:

```sh
cp examples/glass/*.* ~/.t3/shell/
```

| Example     | Idea                                                                                                                                                                                                                                                                                                                                                    |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `minimal`   | The default layout with the title bar moved to the bottom, on the web app's own dark palette (`theme.json` here is the page's default theme, so it is the one to copy when a rice should start from stock colours).                                                                                                                                     |
| `dashboard` | Rosé light theme, an icon rail that also carries settings, and a Dashboard button that pulls a widget drawer over the page: today, the month, the open workspace, thread meters, and the agent, with a cat at play (a Lottie animation; needs the Qt Lottie module, `qt6-lottie` on Arch, and shows the agent's initial without it).                    |
| `glass`     | The shape of a Mac app: one rounded window with a hairline edge, traffic lights, a translucent sidebar for the compositor to blur behind, and a unified toolbar over an opaque content column.                                                                                                                                                          |
| `terminal`  | Status line with the wordmark, a prompt mark, counts and the model; mono type, sharp corners. Made for a tiling desktop such as Omarchy, with flags at the top of `shell.qml` for a clock, window buttons and a chip of the palette's sixteen colours. Its `theme.json` is Tokyo Night as `vp run theme:qt` writes it from a terminal in those colours. |

Pick up your own terminal's colours (it asks the terminal for its palette and
writes `theme.json` into the shell directory, `~/.t3/shell` by default):

```sh
vp run theme:qt
vp run theme:qt ~/.t3/shell
```

On macOS, `glass-macos` follows the system light/dark appearance, with real window traffic lights,
[Qt Quick's macOS controls](https://doc.qt.io/qt-6/qtquickcontrols-macos.html),
and a [qt-liquid-glass](https://github.com/fsalinas26/qt-liquid-glass) backdrop.
Copy all three files (`shell.qml`, `MacToolbar.qml`, and `theme.json`) into
your shell directory, or pass `--config-dir apps/desktop-qt/examples/glass-macos`
to the Qt executable. A rebuild is required for the native backdrop support.
The first macOS configure fetches a pinned dependency; an offline checkout can
be supplied with `-DFETCHCONTENT_SOURCE_DIR_QT_LIQUID_GLASS=/path/to/qt-liquid-glass`.

Glass is confined to navigation and toolbar chrome, with opaque conversation,
code, and terminal content, following Apple's
[Liquid Glass guidance](https://developer.apple.com/documentation/technologyoverviews/liquid-glass)
and [adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).
macOS 26 uses `NSGlassEffectView`; older systems use `NSVisualEffectView`.
Reduce Transparency uses an opaque backing and the standard material. The
variant opts in through `window.liquidGlass` alongside `transparent` and `blur`.
`window.followSystemAppearance` selects the matching `variants.light` or
`variants.dark` colors when the system appearance changes, including while running.
The original `glass` keeps its existing blur. The native controls are macOS-only,
so use `glass` on other platforms.

What you can reach from `shell.qml`: `ShellWindow` as the root (window
colour, opacity and frame from the theme, `sidebarCollapsed` and
`settingsActive` from the page, the error overlay and the page's window
commands built in), the bricks (`TitleBar`, `Sidebar`, `SettingsNav`,
`Workspace`, `GitActions`, `WebSurface`, `Composer`, `RightPanel`, `TerminalDrawer`,
`Notifications`), the themed controls (`ShellCard`, `ShellButton`,
`ShellComboBox`, `ShellTextField`, `ShellMenu`, `ShellMenuItem`, `ShellIcon`,
`WindowControls`), and the `T3.Shell` singletons: `Shell.state.<key>` for
everything the page publishes, `Shell.dispatch(action, payload)` to act,
`Theme.palette.color(role, fallback)` / `Theme.radius` / `Theme.fontUi` /
`Theme.fontMono`, and `Runtime.reload()`.

A broken `shell.qml` never locks you out: the built-in shell takes over with
the error shown in an overlay.
