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
};

QTEST_MAIN(PlatformWindowTest)
#include "tst_PlatformWindow.moc"
