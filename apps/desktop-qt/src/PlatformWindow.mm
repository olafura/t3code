#include "PlatformWindow.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

#include <QGuiApplication>
#include <QPlatformSurfaceEvent>
#include <QStyleHints>
#include <QWindow>
#include "QtLiquidGlassCommon.h"

@interface T3GlassHost : NSView
@end

@implementation T3GlassHost
- (NSView*)hitTest:(NSPoint)point {
  return nil;
}
@end

namespace {

// The pinned library owns the AppKit views; the window owns this handle.
// Surface destruction happens before QWindow's QObject children are deleted.
class LiquidGlassBackdrop final : public QObject {
public:
  explicit LiquidGlassBackdrop(QWindow* window) : QObject(window), m_window(window) {
    window->installEventFilter(this);
    m_observer = [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*) {
          remove();
          update();
        }];
  }

  ~LiquidGlassBackdrop() override {
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:m_observer];
    remove();
  }

  void apply(bool enabled, bool dark) {
    m_enabled = enabled;
    m_dark = dark;
    update();
  }

protected:
  bool eventFilter(QObject* watched, QEvent* event) override {
    if (event->type() == QEvent::PlatformSurface) {
      m_surfaceAvailable = static_cast<QPlatformSurfaceEvent*>(event)->surfaceEventType() ==
                           QPlatformSurfaceEvent::SurfaceCreated;
      if (m_surfaceAvailable) update();
      else remove();
    }
    return QObject::eventFilter(watched, event);
  }

private:
  void remove() {
    if (m_id >= 0) RemoveGlassEffectView(m_id);
    m_id = -1;
    if (m_container != nil) {
      NSWindow* native = m_container.window;
      restoreTitlebar(native);
      native.opaque = m_originalOpaque;
      native.backgroundColor = m_originalBackground;
      [m_originalBackground release];
      m_originalBackground = nil;
      [m_container removeFromSuperview];
      [m_container release];
      m_container = nil;
    }
  }

  void update() {
    if (!m_enabled || !m_surfaceAvailable) {
      remove();
      return;
    }
    if (m_id < 0) {
      const bool reduced = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
      auto* qtView = reinterpret_cast<NSView*>(m_window->winId());
      NSWindow* native = qtView.window;
      m_originalOpaque = native.opaque;
      m_originalBackground = [native.backgroundColor retain];
      native.opaque = NO;
      native.backgroundColor = NSColor.clearColor;
      unifyTitlebar(native);

      // Keep Qt as the native content view; AppKit keeps drawing the title bar
      // (as the toolbar band above when the shell draws under it). The
      // negative layer order puts glass behind Qt's transparent Metal layer.
      m_container = [[T3GlassHost alloc] initWithFrame:qtView.bounds];
      m_container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      m_container.wantsLayer = YES;
      m_container.layer.zPosition = -1;
      [qtView addSubview:m_container positioned:NSWindowBelow relativeTo:nil];
      m_id = AddGlassEffectView(m_container, reduced, 0, 1, reduced);
      SetGlassViewVariant(m_id, 16); // Upstream Material::Sidebar mapping.
      SetGlassViewMaterial(m_id, NSVisualEffectMaterialSidebar);
      ConfigureGlassView(m_id, 0, false, 0, 0, 0, 0, reduced, 0, 1);
      SetGlassViewBlendingMode(m_id, 0);
    }
    SetGlassViewAdaptiveAppearance(m_id, m_dark ? 1 : 0);
  }

  // A shell that draws under the title bar (Qt::ExpandedClientAreaHint) gets
  // the compact toolbar band Mac apps put their controls in: no title, no
  // separator, and an empty toolbar so AppKit centres the traffic lights in a
  // 40 pt strip (the full unified style is 66 pt on macOS 26 with the lights
  // sitting high in it). Qt reports the strip as the top safe area for QML
  // to line its own controls up with. A window that keeps its title bar is
  // left alone.
  void unifyTitlebar(NSWindow* native) {
    const auto mask = native.styleMask;
    if (!(mask & NSWindowStyleMaskTitled) || !(mask & NSWindowStyleMaskFullSizeContentView)) return;
    m_originalTitleVisibility = native.titleVisibility;
    m_originalSeparatorStyle = native.titlebarSeparatorStyle;
    m_originalToolbarStyle = native.toolbarStyle;
    m_originalToolbar = [native.toolbar retain];
    native.titleVisibility = NSWindowTitleHidden;
    native.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    native.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
    if (native.toolbar == nil) {
      NSToolbar* toolbar = [[NSToolbar alloc] initWithIdentifier:@"t3-shell-titlebar"];
      native.toolbar = toolbar;
      [toolbar release];
    }
    m_unifiedTitlebar = true;
  }

  void restoreTitlebar(NSWindow* native) {
    if (!m_unifiedTitlebar) return;
    native.toolbar = m_originalToolbar;
    [m_originalToolbar release];
    m_originalToolbar = nil;
    native.toolbarStyle = m_originalToolbarStyle;
    native.titlebarSeparatorStyle = m_originalSeparatorStyle;
    native.titleVisibility = m_originalTitleVisibility;
    m_unifiedTitlebar = false;
  }

  QWindow* m_window;
  id m_observer = nil;
  NSView* m_container = nil;
  NSColor* m_originalBackground = nil;
  BOOL m_originalOpaque = YES;
  NSToolbar* m_originalToolbar = nil;
  NSWindowTitleVisibility m_originalTitleVisibility = NSWindowTitleVisible;
  NSTitlebarSeparatorStyle m_originalSeparatorStyle = NSTitlebarSeparatorStyleAutomatic;
  NSWindowToolbarStyle m_originalToolbarStyle = NSWindowToolbarStyleAutomatic;
  bool m_unifiedTitlebar = false;
  int m_id = -1;
  bool m_enabled = false;
  bool m_dark = false;
  bool m_surfaceAvailable = true;
};

// WindowServer blur behind a window: pure blur with no tint, so the theme's
// own alpha decides how much of it shows. The same call terminals use for
// their "background blur" option; not public API, hence the dlsym.
bool applyWindowServerBlur(NSWindow* native, int radius) {
  using ConnectionFn = int (*)();
  using BlurFn = int (*)(int, NSInteger, int);
  static const auto connection =
      reinterpret_cast<ConnectionFn>(dlsym(RTLD_DEFAULT, "CGSDefaultConnectionForThread"));
  static const auto setBlur =
      reinterpret_cast<BlurFn>(dlsym(RTLD_DEFAULT, "CGSSetWindowBackgroundBlurRadius"));
  if (connection == nullptr || setBlur == nullptr) {
    return false;
  }
  return setBlur(connection(), native.windowNumber, radius) == 0;
}

void applyEffectView(NSWindow* native, bool enabled, bool dark) {
  NSVisualEffectView* backdrop = nil;
  if ([native.contentView isKindOfClass:[NSVisualEffectView class]]) {
    backdrop = (NSVisualEffectView*)native.contentView;
  } else if (enabled) {
    // Qt's view becomes a child of the effect view: the blur paints below it and
    // Qt keeps drawing on a clear surface on top.
    NSView* content = native.contentView;
    backdrop = [[NSVisualEffectView alloc] initWithFrame:content.frame];
    backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    backdrop.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    native.contentView = backdrop;
    content.frame = backdrop.bounds;
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [backdrop addSubview:content];
  }
  if (backdrop == nil) {
    return;
  }
  backdrop.material = dark ? NSVisualEffectMaterialHUDWindow : NSVisualEffectMaterialPopover;
  backdrop.state = enabled ? NSVisualEffectStateActive : NSVisualEffectStateInactive;
  backdrop.appearance =
      [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
}

}  // namespace

void applyApplicationAppearance(bool enabled, bool dark) {
  if (QGuiApplication::platformName() != QStringLiteral("cocoa")) {
    return;
  }
  QGuiApplication::styleHints()->setColorScheme(
      enabled ? (dark ? Qt::ColorScheme::Dark : Qt::ColorScheme::Light)
              : Qt::ColorScheme::Unknown);
}

void applyWindowBlur(QWindow* window, bool enabled, bool dark, bool liquidGlass) {
  if (window == nullptr || QGuiApplication::platformName() != QStringLiteral("cocoa")) {
    return;
  }
  auto* qtView = reinterpret_cast<NSView*>(window->winId());
  NSWindow* native = qtView.window;
  if (native == nil) {
    return;
  }
  LiquidGlassBackdrop* glass = nullptr;
  for (auto* child : window->children()) {
    if ((glass = dynamic_cast<LiquidGlassBackdrop*>(child))) break;
  }
  if (enabled && liquidGlass) {
    applyWindowServerBlur(native, 0);
    // Undo the older fallback's wrapper so Qt remains a top-level window.
    if ([native.contentView isKindOfClass:[NSVisualEffectView class]]) {
      [qtView retain];
      native.contentView = qtView;
      [qtView release];
    }
    if (glass == nullptr) glass = new LiquidGlassBackdrop(window);
    glass->apply(true, dark);
    return;
  }
  if (glass != nullptr) glass->apply(false, dark);
  if (enabled) {
    native.opaque = NO;
    native.backgroundColor = NSColor.clearColor;
  }
  if (!applyWindowServerBlur(native, enabled ? 32 : 0)) {
    applyEffectView(native, enabled, dark);
  } else if ([native.contentView isKindOfClass:[NSVisualEffectView class]]) {
    applyEffectView(native, false, dark);
  }
}
