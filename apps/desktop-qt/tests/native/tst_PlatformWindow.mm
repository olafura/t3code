#import <AppKit/AppKit.h>

#include <QGuiApplication>
#include <QQuickWindow>
#include <QScopeGuard>
#include <QStyleHints>
#include <QTest>

#include "PlatformWindow.h"

class PlatformWindowTest : public QObject {
  Q_OBJECT

private slots:
  void nativeAppearanceCanReturnToSystemDefault() {
    if (QGuiApplication::platformName() != "cocoa") QSKIP("Requires AppKit");
    auto* hints = QGuiApplication::styleHints();
    hints->unsetColorScheme();
    const auto systemScheme = hints->colorScheme();
    const auto restore = qScopeGuard([&] { hints->unsetColorScheme(); });
    for (bool dark : {false, true}) {
      applyApplicationAppearance(true, dark);
      QTRY_COMPARE(hints->colorScheme(), dark ? Qt::ColorScheme::Dark : Qt::ColorScheme::Light);
      applyApplicationAppearance(false, dark);
      QTRY_COMPARE(hints->colorScheme(), systemScheme);
    }
  }

  void glassPreservesNativeChromeAndQtContentThroughResizeAndRecreation() {
    if (QGuiApplication::platformName() != "cocoa") QSKIP("Requires AppKit");
    QQuickWindow window;
    window.setTitle("Glass lifecycle test");
    window.setColor(Qt::transparent);
    window.resize(800, 600);
    window.create();
    auto* qtView = reinterpret_cast<NSView*>(window.winId());
    NSWindow* native = qtView.window;
    QVERIFY(native != nil);
    QCOMPARE(native.contentView, qtView);
    native.opaque = NO;
    native.backgroundColor = NSColor.clearColor;
    const auto style = native.styleMask;
    const auto closeFrame = [native standardWindowButton:NSWindowCloseButton].frame;
    const auto siblings = qtView.superview.subviews.count;
    const auto children = qtView.subviews.count;

    for (int iteration = 0; iteration < 3; ++iteration) {
      applyWindowBlur(&window, true, false, true);
      QCOMPARE(native.contentView, qtView);
      QCOMPARE(qtView.superview.subviews.count, siblings);
      QCOMPARE(qtView.subviews.count, children + 1);
      NSView* container = qtView.subviews.firstObject;
      QVERIFY(container.subviews.count >= 1);
      QCOMPARE([container hitTest:NSMakePoint(20, 20)], nil);
      QCOMPARE(native.styleMask, style);
      QVERIFY(NSEqualRects([native standardWindowButton:NSWindowCloseButton].frame, closeFrame));
      applyWindowBlur(&window, true, true, true);
      QCOMPARE(native.contentView, qtView);
      QCOMPARE(qtView.subviews.count, children + 1);
      window.resize(900 + iteration * 20, 650);
      QTRY_VERIFY(NSEqualSizes(qtView.frame.size, container.bounds.size));
      applyWindowBlur(&window, false, false, false);
      QCOMPARE(native.contentView, qtView);
      QCOMPARE(qtView.window, native);
      QCOMPARE(qtView.superview.subviews.count, siblings);
      QCOMPARE(qtView.subviews.count, children);
    }

    applyWindowBlur(&window, true, false, true);
    window.destroy();
    window.create();
    qtView = reinterpret_cast<NSView*>(window.winId());
    native = qtView.window;
    QCOMPARE(native.contentView, qtView);
    QCOMPARE(qtView.subviews.count, children + 1);
    applyWindowBlur(&window, false, false, false);
    QCOMPARE(native.contentView, qtView);
  }

  void glassUnifiesTheTitleBarOnlyWhenTheShellDrawsUnderIt() {
    if (QGuiApplication::platformName() != "cocoa") QSKIP("Requires AppKit");
    QQuickWindow window;
    window.setFlags(Qt::Window | Qt::ExpandedClientAreaHint | Qt::NoTitleBarBackgroundHint);
    window.setTitle("Unified title bar test");
    window.resize(800, 600);
    window.create();
    auto* qtView = reinterpret_cast<NSView*>(window.winId());
    NSWindow* native = qtView.window;
    QVERIFY(native != nil);
    QVERIFY(native.styleMask & NSWindowStyleMaskFullSizeContentView);
    QCOMPARE(native.toolbar, nil);
    const auto style = native.styleMask;
    NSButton* close = [native standardWindowButton:NSWindowCloseButton];
    const auto lightsFromTop = [&] {
      [close.superview layoutSubtreeIfNeeded];
      const NSRect frame = [close convertRect:close.bounds toView:nil];
      return NSHeight(native.contentView.frame) - NSMidY(frame);
    };
    const auto original = lightsFromTop();

    applyWindowBlur(&window, true, true, true);
    QVERIFY(native.toolbar != nil);
    QCOMPARE(native.toolbar.items.count, 0u);
    QCOMPARE(native.titleVisibility, NSWindowTitleHidden);
    QCOMPARE(native.titlebarSeparatorStyle, NSTitlebarSeparatorStyleNone);
    QCOMPARE(native.toolbarStyle, NSWindowToolbarStyleUnifiedCompact);
    QCOMPARE(native.styleMask, style);
    // The traffic lights move down to the centre of the taller band, which
    // is what the shell's title strip lines up with.
    QTRY_VERIFY2(lightsFromTop() > original, qPrintable(QString("close button centre %1 -> %2, safe area top %3")
        .arg(original).arg(lightsFromTop()).arg(window.safeAreaMargins().top())));
    QTRY_VERIFY(window.safeAreaMargins().top() >= 36);
    QVERIFY(qAbs(lightsFromTop() - window.safeAreaMargins().top() / 2.0) <= 2);

    applyWindowBlur(&window, false, false, false);
    QCOMPARE(native.toolbar, nil);
    QCOMPARE(native.titleVisibility, NSWindowTitleVisible);
    QTRY_COMPARE(lightsFromTop(), original);

    // A window that keeps its title bar keeps its title.
    QQuickWindow plain;
    plain.setTitle("Plain title bar test");
    plain.resize(800, 600);
    plain.create();
    NSWindow* plainNative = reinterpret_cast<NSView*>(plain.winId()).window;
    applyWindowBlur(&plain, true, true, true);
    QCOMPARE(plainNative.toolbar, nil);
    QCOMPARE(plainNative.titleVisibility, NSWindowTitleVisible);
    applyWindowBlur(&plain, false, false, false);
  }
};

QTEST_MAIN(PlatformWindowTest)
#include "tst_PlatformWindow.moc"
