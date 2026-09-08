#include <QFile>
#include <QGuiApplication>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWebEngineProfile>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QWebChannel>
#include <QtWebEngineQuick>
#include <memory>

#include "ShellBridge.h"
#include "ThemeStore.h"
#include "WebProfile.h"

class AppViewsTest : public QObject {
  Q_OBJECT

  QTemporaryDir directory;
  ShellBridge bridge;
  std::unique_ptr<ThemeStore> theme;
  std::unique_ptr<WebProfile> profile;
  std::unique_ptr<QQmlEngine> engine;
  std::unique_ptr<QQmlComponent> component;

  QVariant evaluate(QObject* window, const QString& script) {
    QSignalSpy completed(window, SIGNAL(scriptCompleted()));
    if (!QMetaObject::invokeMethod(window, "evaluate", Q_ARG(QVariant, script))) return {};
    if (completed.isEmpty() && !completed.wait(10000)) return {};
    return window->property("scriptResult");
  }

private slots:
  void initTestCase() {
    QVERIFY(directory.isValid());
    QFile page(directory.filePath("app.html"));
    QVERIFY(page.open(QIODevice::WriteOnly));
    page.write("<!doctype html><title>Independent client</title><input id='draft'>"
               "<script>window.storageIdAtStartup = window.__t3AppViewStorageId;</script>");
    page.close();
    bridge.setPageUrl(QUrl::fromLocalFile(page.fileName()));
    theme = std::make_unique<ThemeStore>(directory.path());
    profile = std::make_unique<WebProfile>(directory.filePath("web"));
    qmlRegisterSingletonInstance("T3.Shell", 1, 0, "Shell", &bridge);
    qmlRegisterSingletonInstance("T3.Shell", 1, 0, "Theme", theme.get());
    qmlRegisterSingletonInstance("T3.Shell", 1, 0, "WebProfile", profile->profile());
    engine = std::make_unique<QQmlEngine>();
    engine->addImportPath(QStringLiteral(T3_TEST_SOURCE_DIR "/qml"));
    component = std::make_unique<QQmlComponent>(engine.get());
    component->setData(R"(
      import QtQuick
      import T3.Bricks
      AppWindow {
        id: root
        property var scriptResult: null
        signal scriptCompleted()
        function evaluate(script) {
          const view = root.contentItem.children.find(item => item.objectName === "independentAppView");
          view.runJavaScript(script, result => {
            root.scriptResult = result;
            root.scriptCompleted();
          });
        }
      }
    )", QUrl::fromLocalFile(directory.filePath("test.qml")));
    QVERIFY2(component->isReady(), qPrintable(component->errorString()));
  }

  void windowsShareAuthenticationStorageWithoutSharingActionsOrNavigation() {
    std::unique_ptr<QObject> first(component->createWithInitialProperties({{"storageId", "window-a"}}));
    std::unique_ptr<QObject> second(component->createWithInitialProperties({{"storageId", "window-b"}}));
    QVERIFY2(first, qPrintable(component->errorString()));
    QVERIFY2(second, qPrintable(component->errorString()));
    auto* firstWindow = qobject_cast<QQuickWindow*>(first.get());
    auto* secondWindow = qobject_cast<QQuickWindow*>(second.get());
    QVERIFY(firstWindow);
    QVERIFY(secondWindow);
    auto* firstView = first->findChild<QQuickItem*>("independentAppView");
    auto* secondView = second->findChild<QQuickItem*>("independentAppView");
    QVERIFY(firstView);
    QVERIFY(secondView);
    QTRY_COMPARE(firstView->property("title").toString(), QString("Independent client"));
    QTRY_COMPARE(secondView->property("title").toString(), QString("Independent client"));

    QCOMPARE(firstView->property("profile").value<QObject*>(), profile->profile());
    QCOMPARE(secondView->property("profile").value<QObject*>(), profile->profile());
    // WebEngine may supply an empty default channel even when assigned null.
    // No native bridge object may be registered on an independent page.
    for (auto* view : {firstView, secondView}) {
      auto* channel = qobject_cast<QWebChannel*>(view->property("webChannel").value<QObject*>());
      QVERIFY(!channel || channel->registeredObjects().isEmpty());
    }
    QCOMPARE(evaluate(first.get(), "typeof window.t3Shell").toString(), QString("undefined"));
    QCOMPARE(evaluate(second.get(), "typeof window.t3Shell").toString(), QString("undefined"));
    QCOMPARE(evaluate(first.get(), "window.storageIdAtStartup").toString(), QString("window-a"));
    QCOMPARE(evaluate(second.get(), "window.storageIdAtStartup").toString(), QString("window-b"));

    QCOMPARE(evaluate(first.get(), "localStorage.setItem('session-fixture', 'paired'); localStorage.getItem('session-fixture')").toString(), QString("paired"));
    QCOMPARE(evaluate(second.get(), "localStorage.getItem('session-fixture')").toString(), QString("paired"));
    QCOMPARE(evaluate(first.get(), "location.hash = 'thread-a'; document.querySelector('input').value = 'draft a'").toString(), QString("draft a"));
    QCOMPARE(evaluate(second.get(), "location.hash = 'thread-b'; document.querySelector('input').value = 'draft b'").toString(), QString("draft b"));
    bridge.dispatch("composer.clear");
    bridge.windowCommand("close");
    QCOMPARE(evaluate(first.get(), "location.hash + ':' + document.querySelector('input').value").toString(), QString("#thread-a:draft a"));
    QCOMPARE(evaluate(second.get(), "location.hash + ':' + document.querySelector('input').value").toString(), QString("#thread-b:draft b"));
    QVERIFY(firstWindow->isVisible());
    QVERIFY(secondWindow->isVisible());

    firstWindow->close();
    QVERIFY(!firstWindow->isVisible());
    QVERIFY(secondWindow->isVisible());
    QCOMPARE(evaluate(second.get(), "document.querySelector('input').value").toString(), QString("draft b"));
  }

  void ownedWindowsRemainIndependentTopLevels() {
    QQmlComponent fixture(engine.get());
    fixture.setData(R"(
      import QtQuick
      import T3.Bricks
      Window {
        id: root
        width: 320; height: 240; visible: true
        function openWindow() { return childWindow.createObject(root); }
        Component { id: childWindow; AppWindow {} }
      }
    )", QUrl::fromLocalFile(directory.filePath("owned.qml")));
    QVERIFY2(fixture.isReady(), qPrintable(fixture.errorString()));
    std::unique_ptr<QObject> owner(fixture.create());
    QVERIFY2(owner, qPrintable(fixture.errorString()));
    QVariant result;
    QVERIFY(QMetaObject::invokeMethod(owner.get(), "openWindow", Q_RETURN_ARG(QVariant, result)));
    QPointer<QQuickWindow> child = qobject_cast<QQuickWindow*>(result.value<QObject*>());
    QVERIFY(child);
    QCOMPARE(child->parent(), nullptr);
    QCOMPARE(child->transientParent(), nullptr);
    QVERIFY(child->isVisible());
    owner.reset();
    QVERIFY(child.isNull());
  }

  void transparentCanvasClearsOnlyBackdropsAndRestoresThem_data() {
    QTest::addColumn<bool>("initiallyTransparent");
    QTest::newRow("opaque-default") << false;
    QTest::newRow("transparent-at-startup") << true;
  }

  void transparentCanvasClearsOnlyBackdropsAndRestoresThem() {
    QFETCH(bool, initiallyTransparent);
    QFile stylesheet(QStringLiteral(T3_TEST_SOURCE_DIR "/../web/src/index.css"));
    QVERIFY(stylesheet.open(QIODevice::ReadOnly));
    const QByteArray css = stylesheet.readAll();
    const auto start = css.indexOf("html[data-shell-surface-transparent]");
    QVERIFY(start >= 0);
    const auto end = css.indexOf("\npre,", start);
    QVERIFY(end > start);
    QFile page(directory.filePath("transparent.html"));
    QVERIFY(page.open(QIODevice::WriteOnly));
    page.write("<!doctype html><title>Canvas fixture</title><script>"
               "window.transparentAtStartup = 'shellSurfaceTransparent' in document.documentElement.dataset;"
               "</script><style>html,body,#root,main,[data-shell-chat-canvas]{background:#fbf1ed}"
               "#message,#code,#menu{background:#fff7f4}");
    page.write(css.mid(start, end - start));
    page.write("</style><div id='root'><main data-slot='sidebar-inset'>"
               "<div id='canvas' data-shell-chat-canvas><div id='message'>Message</div>"
               "<pre id='code'>Code</pre><div id='menu' role='menu'>Menu</div></div>"
               "</main></div><main id='settings' data-slot='sidebar-inset'>Settings</main>");
    page.close();
    QQmlComponent fixture(engine.get());
    fixture.setData(R"(
      import QtQuick
      import T3.Bricks
      Window {
        id: root
        width: 320; height: 240; visible: true
        property bool initiallyTransparent: false
        property url pageUrl
        property alias transparentCanvas: view.transparentCanvas
        property var scriptResult: null
        signal scriptCompleted()
        function evaluate(script) {
          view.runJavaScript(script, result => {
            root.scriptResult = result;
            root.scriptCompleted();
          });
        }
        WebSurface {
          id: view
          objectName: "canvasView"
          anchors.fill: parent
          shellIntegration: false
          transparentCanvas: root.initiallyTransparent
          url: root.pageUrl
        }
      }
    )", QUrl::fromLocalFile(directory.filePath("canvas.qml")));
    QVERIFY2(fixture.isReady(), qPrintable(fixture.errorString()));
    std::unique_ptr<QObject> window(fixture.createWithInitialProperties({
        {"initiallyTransparent", initiallyTransparent}, {"pageUrl", QUrl::fromLocalFile(page.fileName())}}));
    QVERIFY2(window, qPrintable(fixture.errorString()));
    auto* view = window->findChild<QQuickItem*>("canvasView");
    QVERIFY(view);
    QTRY_COMPARE(view->property("title").toString(), QString("Canvas fixture"));
    QCOMPARE(evaluate(window.get(), "window.transparentAtStartup").toBool(), initiallyTransparent);

    const QString colors = QStringLiteral(
        "['root','canvas','message','code','menu','settings'].map(id => getComputedStyle(document.getElementById(id)).backgroundColor).join('|')");
    const QString opaque = QStringLiteral("rgb(251, 241, 237)|rgb(251, 241, 237)|rgb(255, 247, 244)|rgb(255, 247, 244)|rgb(255, 247, 244)|rgb(251, 241, 237)");
    const QString transparent = QStringLiteral("rgba(0, 0, 0, 0)|rgba(0, 0, 0, 0)|rgb(255, 247, 244)|rgb(255, 247, 244)|rgb(255, 247, 244)|rgb(251, 241, 237)");
    QCOMPARE(evaluate(window.get(), colors).toString(), initiallyTransparent ? transparent : opaque);
    for (const bool enabled : {true, false, true}) {
      QVERIFY(window->setProperty("transparentCanvas", enabled));
      QTRY_COMPARE(evaluate(window.get(), colors).toString(), enabled ? transparent : opaque);
      QCOMPARE(evaluate(window.get(), "'shellSurfaceTransparent' in document.documentElement.dataset").toBool(), enabled);
      QCOMPARE(view->property("backgroundColor").value<QColor>().alpha() == 0, enabled);
    }
  }

  void cleanupTestCase() {
    component.reset();
    engine.reset();
    profile.reset();
    theme.reset();
  }
};

int main(int argc, char** argv) {
  QtWebEngineQuick::initialize();
  QGuiApplication app(argc, argv);
  AppViewsTest test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_AppViews.moc"
