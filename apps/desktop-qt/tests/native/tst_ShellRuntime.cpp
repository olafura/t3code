#include <QFile>
#include <QFileInfo>
#include <QPointer>
#include <QQmlComponent>
#include <QQmlContext>
#include <QSignalSpy>
#include <QQuickWebEngineProfile>
#include <QTemporaryDir>
#include <QTest>
#include <QtWebEngineQuick>
#include <QWebEnginePage>
#include <QWebEngineProfile>

#include "ShellBridge.h"
#include "ShellRuntime.h"
#include "ThemeStore.h"
#include "WebProfile.h"

class ShellRuntimeTest : public QObject {
  Q_OBJECT

signals:
  void scriptFinished(const QVariant& result);

private slots:
  void qmlPaletteFollowsPublishedPageTheme() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    ThemeStore theme(directory.path());
    QQmlEngine engine;
    engine.rootContext()->setContextProperty("Theme", &theme);
    QQmlComponent component(&engine);
    component.setData("import QtQuick\nRectangle { color: Theme.palette.color(\"canvas\", \"#111111\") }", QUrl());
    QScopedPointer<QObject> item(component.create());
    QVERIFY2(item, qPrintable(component.errorString()));
    QCOMPARE(item->property("color").value<QColor>(), QColor("#111111"));
    theme.applyPageTheme(QVariantMap{{"appearance", "light"}, {"colors", QVariantMap{{"canvas", "#ffffff"}}}});
    QCOMPARE(theme.color("canvas", Qt::black), QColor("#ffffff"));
    QCOMPARE(item->property("color").value<QColor>(), QColor("#ffffff"));
    theme.applyPageTheme(QVariantMap{{"appearance", "dark"}, {"colors", QVariantMap{{"canvas", "#0c2238cc"}}}});
    QCOMPARE(item->property("color").value<QColor>(), QColor(12, 34, 56, 204));
    QFile overrideFile(directory.filePath("theme.json"));
    QVERIFY(overrideFile.open(QIODevice::WriteOnly));
    overrideFile.write("{\"colors\":{\"canvas\":\"#abcdef\"}}");
    overrideFile.close();
    theme.reload();
    QCOMPARE(item->property("color").value<QColor>(), QColor("#abcdef"));
    QVERIFY(overrideFile.remove());
    theme.reload();
    QCOMPARE(item->property("color").value<QColor>(), QColor(12, 34, 56, 204));
  }

  void folderDropsResolveOnlyExistingLocalDirectories() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    ShellBridge bridge;
    const auto url = QUrl::fromLocalFile(directory.path());
    QVERIFY(bridge.localDirectoryPath(url).isEmpty());
    bridge.setPageUrl(QUrl("https://remote.example/thread"));
    QVERIFY(bridge.localDirectoryPath(url).isEmpty());
    bridge.setPageUrl(QUrl("http://127.0.0.1:6182/thread"));
    QVERIFY(bridge.localDirectoryPath(url).isEmpty());
    QSignalSpy dispatched(&bridge, &ShellBridge::actionRequested);
    const QVariantMap request{{QStringLiteral("path"), directory.path()}};
    bridge.dispatch(QStringLiteral("project.folder.open"), request);
    QCOMPARE(dispatched.count(), 0);
    bridge.setLocalFolderImportEnabled(true);
    QCOMPARE(bridge.localDirectoryPath(url), QFileInfo(directory.path()).canonicalFilePath());
    bridge.dispatch(QStringLiteral("project.folder.open"), request);
    QCOMPARE(dispatched.count(), 1);
    QCOMPARE(dispatched.first().at(1).toMap().value(QStringLiteral("path")).toString(), QFileInfo(directory.path()).canonicalFilePath());
    QVERIFY(bridge.localDirectoryPath(QUrl("https://example.com/folder")).isEmpty());
    QVERIFY(bridge.localDirectoryPath(QUrl("file://server/share")).isEmpty());
    QVERIFY(bridge.localDirectoryPath(QUrl::fromLocalFile(directory.filePath("missing"))).isEmpty());
    QFile file(directory.filePath("file.txt"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.close();
    QVERIFY(bridge.localDirectoryPath(QUrl::fromLocalFile(file.fileName())).isEmpty());
    bridge.setPageUrl(QUrl("https://remote.example/thread"));
    QVERIFY(bridge.localDirectoryPath(url).isEmpty());
    bridge.dispatch(QStringLiteral("project.folder.open"), request);
    QCOMPARE(dispatched.count(), 1);
  }

  void appPermissionsRequireMatchingHttpOrigin() {
    ShellBridge bridge;
    bridge.setPageUrl(QUrl("https://EXAMPLE.com/thread?id=1"));
    QVERIFY(bridge.isAppOrigin(QUrl("https://example.com:443/")));
    QVERIFY(!bridge.isAppOrigin(QUrl("http://example.com/")));
    QVERIFY(!bridge.isAppOrigin(QUrl("https://example.com:8443/")));
    QVERIFY(!bridge.isAppOrigin(QUrl("https://example.com.evil.test/")));
    QVERIFY(!bridge.isAppOrigin(QUrl("https://example.com@evil.test/")));
    bridge.setPageUrl(QUrl("http://127.0.0.1:6182/thread"));
    QVERIFY(bridge.isAppOrigin(QUrl("http://127.0.0.1:6182/")));
    QVERIFY(!bridge.isAppOrigin(QUrl("http://127.0.0.1:6183/")));
    bridge.setPageUrl(QUrl("file:///tmp/shell.html"));
    QVERIFY(!bridge.isAppOrigin(bridge.pageUrl()));
    bridge.setPageUrl(QUrl());
    QVERIFY(!bridge.isAppOrigin(QUrl()));
  }

  void themeRecoversAfterReadFailureWithoutAcceptingInvalidJson() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QFile file(directory.filePath("theme.json"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("{\"colors\":{\"canvas\":\"#123456\"}}");
    file.close();
    ThemeStore theme(directory.path());
    QVERIFY(theme.lastError().isEmpty());
    const auto permissions = file.permissions();
    QVERIFY(file.setPermissions(QFile::WriteOwner));
    theme.reload();
    QVERIFY(!theme.lastError().isEmpty());
    QVERIFY(file.setPermissions(permissions));
    theme.reload();
    QVERIFY(theme.lastError().isEmpty());
    QCOMPARE(theme.color("canvas", Qt::black), QColor("#123456"));

    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write("invalid JSON");
    file.close();
    theme.reload();
    QVERIFY(!theme.lastError().isEmpty());
    theme.reload();
    QVERIFY(!theme.lastError().isEmpty());
    QCOMPARE(theme.color("canvas", Qt::black), QColor("#123456"));
  }

  void legacyThemeRemovalRestoresDocumentState() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QFile file(directory.filePath("theme.json"));
    const QByteArray source = "{\"id\":\"shell-night\",\"appearance\":\"dark\",\"colors\":{\"canvas\":\"#123456\",\"chrome\":\"#234567\"}}";
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(source);
    file.close();
    ThemeStore theme(directory.path());
    QWebEngineProfile profile;
    QWebEnginePage page(&profile);
    QSignalSpy loaded(&page, &QWebEnginePage::loadFinished);
    page.setHtml("<!doctype html><html><body>Legacy theme test</body></html>");
    QVERIFY(loaded.wait());
    const auto evaluate = [&](const QString& script) {
      QSignalSpy completed(this, &ShellRuntimeTest::scriptFinished);
      page.runJavaScript(script, [this](const QVariant& result) { emit scriptFinished(result); });
      if (completed.isEmpty() && !completed.wait()) return QVariant();
      return completed.first().first();
    };
    evaluate(R"(
      const root = document.documentElement;
      root.dataset.themeId = 'page';
      root.dataset.themeSelected = 'false';
      root.classList.add('unrelated');
      root.style.setProperty('background-color', 'rgb(12, 34, 56)', 'important');
      root.style.setProperty('--app-theme-canvas', '#654321', 'important');
      window.snapshot = () => JSON.stringify([
        root.getAttribute('data-theme-id'), root.getAttribute('data-theme-selected'),
        root.className, root.style.getPropertyValue('background-color'),
        root.style.getPropertyPriority('background-color'),
        root.style.getPropertyValue('--app-theme-canvas'),
        root.style.getPropertyPriority('--app-theme-canvas')
      ]);
    )");
    const auto original = evaluate("snapshot()");
    evaluate(theme.injectionScript());
    QVERIFY(evaluate("snapshot()") != original);
    evaluate(theme.injectionScript());
    QVERIFY(file.remove());
    theme.reload();
    evaluate(theme.injectionScript());
    QCOMPARE(evaluate("snapshot()"), original);
    QCOMPARE(evaluate("window.__t3ShellTheme.observer === null").toBool(), true);
    QCOMPARE(evaluate("document.documentElement.style.getPropertyValue('--app-theme-chrome')").toString(), QString());

    evaluate("document.documentElement.removeAttribute('data-theme-id'); document.documentElement.removeAttribute('data-theme-selected');");
    const auto withoutAttributes = evaluate("snapshot()");
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(source);
    file.close();
    theme.reload();
    evaluate(theme.injectionScript());
    QVERIFY(file.remove());
    theme.reload();
    evaluate(theme.injectionScript());
    QCOMPARE(evaluate("snapshot()"), withoutAttributes);
  }

  void themeBootstrapHandsOffWithoutRewritingThePage() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QFile file(directory.filePath("theme.json"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("{\"id\":\"shell-night\",\"appearance\":\"dark\",\"colors\":{\"canvas\":\"#123456\"}}");
    file.close();
    ThemeStore theme(directory.path());
    QWebEngineProfile profile;
    QWebEnginePage page(&profile);
    QSignalSpy loaded(&page, &QWebEnginePage::loadFinished);
    page.setHtml("<!doctype html><html><body>Theme test</body></html>");
    QVERIFY(loaded.wait());
    QVERIFY(loaded.first().first().toBool());
    const auto evaluate = [&](const QString& source) {
      QSignalSpy completed(this, &ShellRuntimeTest::scriptFinished);
      page.runJavaScript(source, [this](const QVariant& result) { emit scriptFinished(result); });
      if (completed.isEmpty() && !completed.wait()) return QVariant();
      return completed.first().first();
    };
    evaluate(theme.injectionScript());
    QCOMPARE(evaluate("document.documentElement.dataset.themeId").toString(), QString("shell-night"));
    // Unclaimed/older pages still recover when their own palette overwrites the bootstrap.
    evaluate("document.documentElement.dataset.themeId = 'page';");
    QCOMPARE(evaluate("document.documentElement.dataset.themeId").toString(), QString("shell-night"));
    evaluate(R"(
      window.__t3ShellTheme.observer.disconnect();
      window.__t3ShellTheme.observer = null;
      window.__t3ShellTheme.applyOverride = value => { window.deliveredTheme = value; };
      document.documentElement.dataset.themeId = 'page-owned';
    )");
    evaluate(theme.injectionScript());
    QCOMPARE(evaluate("window.deliveredTheme.id").toString(), QString("shell-night"));
    QCOMPARE(evaluate("document.documentElement.dataset.themeId").toString(), QString("page-owned"));
    QCOMPARE(evaluate("window.__t3ShellTheme.observer === null").toBool(), true);
    const QString beforePublication = theme.injectionScript();
    theme.applyPageTheme(QVariantMap{{"appearance", "light"}, {"colors", QVariantMap{{"canvas", "#ffffff"}}}});
    QCOMPARE(theme.injectionScript(), beforePublication);
    QVERIFY(file.remove());
    theme.reload();
    evaluate(theme.injectionScript());
    QCOMPARE(evaluate("window.deliveredTheme.id").toString(), QString());
  }

  void reloadKeepsSingletonsAndRecoversFromInvalidSource() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QString config = directory.filePath("config");
    const QString sources = directory.filePath("qml");
    QVERIFY(QDir().mkpath(config));
    QVERIFY(QDir().mkpath(sources + "/T3/Bricks"));
    const QString shellPath = config + "/shell.qml";
    const QString defaultPath = sources + "/T3/Bricks/DefaultShell.qml";
    const auto writeSource = [](const QString& path, const QByteArray& contents) {
      QFile file(path);
      return file.open(QIODevice::WriteOnly) && file.write(contents) == contents.size();
    };
    const auto source = [](int revision) {
      return QByteArray(R"(
import QtQuick
import T3.Shell
Window {
  objectName: "reload-probe"
  property int revision: )") + QByteArray::number(revision) + QByteArray(revision, ' ') + R"(
  property int protocol: Shell.protocolVersion
  property string prompt: Shell.state.composer.text
  property real radiusValue: Theme.radius
  property string configValue: Runtime.configDir
  property string profileName: WebProfile.storageName
}
)";
    };
    QVERIFY(writeSource(shellPath, source(1)));
    QVERIFY(writeSource(defaultPath, source(0)));
    ShellBridge bridge;
    bridge.publish("composer", QVariantMap{{"text", "Retained draft"}});
    ThemeStore theme(config);
    WebProfile webProfile(directory.filePath("web"));
    qmlRegisterSingletonInstance("T3.Shell", 1, 0, "WebProfile", webProfile.profile());
    ShellRuntime runtime({config, sources}, &bridge, &theme);
    const auto window = []() -> QQuickWindow* {
      QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
      for (auto* candidate : QGuiApplication::allWindows()) {
        if (candidate->objectName() == "reload-probe") return qobject_cast<QQuickWindow*>(candidate);
      }
      return nullptr;
    };
    const auto verifySingletons = [&](QQuickWindow* root) {
      QVERIFY(root);
      QCOMPARE(root->property("protocol").toInt(), bridge.protocolVersion());
      QCOMPARE(root->property("prompt").toString(), QString("Retained draft"));
      QCOMPARE(root->property("radiusValue").toReal(), theme.radius());
      QCOMPARE(root->property("configValue").toString(), config);
      QCOMPARE(root->property("profileName").toString(), webProfile.profile()->storageName());
    };
    runtime.start();
    verifySingletons(window());
    for (int revision = 2; revision <= 3; ++revision) {
      QPointer<QQuickWindow> previous = window();
      QVERIFY(writeSource(shellPath, source(revision)));
      runtime.reload();
      verifySingletons(window());
      QVERIFY(previous.isNull());
      QCOMPARE(window()->property("revision").toInt(), revision);
      QCOMPARE(runtime.generation(), revision);
    }
    QPointer<QQuickWindow> working = window();
    QVERIFY(writeSource(shellPath, "invalid QML"));
    QVERIFY(writeSource(defaultPath, "invalid QML"));
    runtime.reload();
    QCOMPARE(window(), working.data());
    QCOMPARE(runtime.generation(), 3);
    QVERIFY(!runtime.lastError().isEmpty());
    verifySingletons(window());

    QVERIFY(writeSource(defaultPath, source(4)));
    runtime.reload();
    verifySingletons(window());
    QCOMPARE(window()->property("revision").toInt(), 4);
    QVERIFY(!runtime.usingUserShell());
    QVERIFY(writeSource(shellPath, source(5)));
    runtime.reload();
    verifySingletons(window());
    QCOMPARE(window()->property("revision").toInt(), 5);
    QVERIFY(runtime.usingUserShell());
    QVERIFY(runtime.lastError().isEmpty());

    QVERIFY(writeSource(shellPath, source(6)));
    QTRY_COMPARE(runtime.generation(), 6);
    verifySingletons(window());
    QCOMPARE(window()->property("revision").toInt(), 6);

    QVERIFY(writeSource(shellPath, "import QtQml\nQtObject {}"));
    runtime.reload();
    QVERIFY(window());
    verifySingletons(window());
    QCOMPARE(window()->property("revision").toInt(), 4);
    QVERIFY(!runtime.usingUserShell());
    QVERIFY(runtime.lastError().contains("Window"));
    auto* engine = runtime.findChild<QQmlApplicationEngine*>();
    QVERIFY(engine);
    QTRY_COMPARE(engine->rootObjects().size(), 1);

    working = window();
    const int generation = runtime.generation();
    QVERIFY(writeSource(defaultPath, "import QtQml\nQtObject {}"));
    runtime.reload();
    QCOMPARE(window(), working.data());
    QCOMPARE(runtime.generation(), generation);
    QCOMPARE(engine->rootObjects().size(), 1);
  }
};

int main(int argc, char** argv) {
  QtWebEngineQuick::initialize();
  QGuiApplication app(argc, argv);
  ShellRuntimeTest test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_ShellRuntime.moc"
