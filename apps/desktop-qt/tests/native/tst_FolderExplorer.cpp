#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QTest>
#include <memory>

#include "LocalFolderModel.h"
#include "ShellBridge.h"
#include "ThemeStore.h"

class FolderExplorerTest : public QObject {
  Q_OBJECT
  QTemporaryDir directory;
  ShellBridge bridge;
  std::unique_ptr<ThemeStore> theme;
  std::unique_ptr<QQmlEngine> engine;

private slots:
  void initTestCase() {
    QVERIFY(directory.isValid());
    bridge.setPageUrl(QUrl("http://localhost:6183"));
    bridge.setLocalFolderImportEnabled(true);
    bridge.publish("sidebar", QVariantMap{{"localEnvironmentId", "local"}, {"localProjects", QVariantList{}}});
    theme = std::make_unique<ThemeStore>(directory.path());
    qmlRegisterSingletonInstance("T3.Shell", 1, 0, "Shell", &bridge);
    qmlRegisterSingletonInstance("T3.Shell", 1, 0, "Theme", theme.get());
    qmlRegisterType<LocalFolderModel>("T3.Shell", 1, 0, "LocalFolderModel");
    engine = std::make_unique<QQmlEngine>();
    engine->addImportPath(QStringLiteral(T3_TEST_SOURCE_DIR "/qml"));
  }

  void dialogsOperateOnRealFoldersAndCancellationPreservesThem() {
    QQmlComponent component(engine.get());
    component.setData(R"(
      import QtQuick
      import T3.Bricks
      Window {
        id: window
        width: 900; height: 700; visible: true
        property string directory
        FolderExplorer { anchors.fill: parent; rootPath: window.directory }
      }
    )", QUrl::fromLocalFile(directory.filePath("fixture.qml")));
    QVERIFY2(component.isReady(), qPrintable(component.errorString()));
    std::unique_ptr<QObject> root(component.createWithInitialProperties({{"directory", directory.path()}}));
    QVERIFY2(root, qPrintable(component.errorString()));
    auto* window = qobject_cast<QQuickWindow*>(root.get());
    auto* explorer = root->findChild<QQuickItem*>("folderExplorer");
    auto* input = root->findChild<QQuickItem*>("folderOperationInput");
    auto* confirm = root->findChild<QQuickItem*>("folderOperationConfirm");
    auto* cancel = root->findChild<QQuickItem*>("folderOperationCancel");
    auto* dialog = root->findChild<QObject*>("folderOperationDialog");
    QVERIFY(window && explorer && input && confirm && cancel && dialog);
    auto click = [window](QQuickItem* item) {
      QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier,
                       item->mapToScene(QPointF(item->width() / 2, item->height() / 2)).toPoint());
    };
    auto begin = [explorer](const QString& operation) {
      return QMetaObject::invokeMethod(explorer, "beginOperation", Q_ARG(QVariant, operation));
    };

    QVERIFY(begin("create"));
    QTRY_VERIFY(dialog->property("opened").toBool());
    input->setProperty("text", "drafts");
    click(confirm);
    QTRY_VERIFY(QFileInfo::exists(directory.filePath("drafts")));
    QTRY_VERIFY(!dialog->property("visible").toBool());
    QCOMPARE(explorer->property("selectedPath").toString(), directory.filePath("drafts"));

    QVERIFY(begin("rename"));
    QTRY_VERIFY(dialog->property("opened").toBool());
    input->setProperty("text", "design");
    click(confirm);
    QTRY_VERIFY(QFileInfo::exists(directory.filePath("design")));
    QVERIFY(!QFileInfo::exists(directory.filePath("drafts")));
    QTRY_VERIFY(!dialog->property("visible").toBool());

    QVERIFY(QDir(directory.path()).mkdir("archive"));
    QVERIFY(begin("move"));
    QTRY_VERIFY(dialog->property("opened").toBool());
    input->setProperty("text", directory.filePath("archive"));
    click(confirm);
    QTRY_VERIFY(QFileInfo::exists(directory.filePath("archive/design")));
    QVERIFY(!QFileInfo::exists(directory.filePath("design")));
    QTRY_VERIFY(!dialog->property("visible").toBool());

    QVERIFY(begin("trash"));
    QTRY_VERIFY(dialog->property("opened").toBool());
    QVERIFY(!confirm->isEnabled());
    input->setProperty("text", "wrong folder");
    QVERIFY(!confirm->isEnabled());
    input->setProperty("text", "design");
    QVERIFY(confirm->isEnabled());
    click(cancel);
    QTRY_VERIFY(!dialog->property("visible").toBool());
    QVERIFY(QFileInfo::exists(directory.filePath("archive/design")));

    QVERIFY(begin("rename"));
    QTRY_VERIFY(dialog->property("opened").toBool());
    input->setProperty("text", "../escape");
    click(confirm);
    QVERIFY(dialog->property("visible").toBool());
    QVERIFY(!root->findChild<QObject*>("folderOperationError")->property("text").toString().isEmpty());
    QVERIFY(QFileInfo::exists(directory.filePath("archive/design")));
    click(cancel);

    QVERIFY(explorer->property("canModifySelection").toBool());
    bridge.publish("sidebar", QVariantMap{{"localEnvironmentId", "local"}, {"localProjects", QVariantList{
      QVariantMap{{"workspaceRoot", directory.filePath("archive/design")}, {"displayName", "Design"}},
      QVariantMap{{"workspaceRoot", directory.path()}, {"displayName", "Workspace"}}
    }}});
    QTRY_VERIFY(!explorer->property("canModifySelection").toBool());
    auto* picker = root->findChild<QObject*>("localFolderProjectPicker");
    QVERIFY(picker);
    QCOMPARE(picker->property("currentIndex").toInt(), 1);
    QCOMPARE(picker->property("displayText").toString(), QString("Workspace"));
    bridge.publish("sidebar", QVariantMap{{"localEnvironmentId", "local"}, {"localProjects", QVariantList{}}});
    QTRY_VERIFY(explorer->property("canModifySelection").toBool());
  }

  void expandedRowsKeepTheirOwnPathsAndDepths() {
    QTemporaryDir fixture;
    QVERIFY(fixture.isValid());
    for (const auto& path : {"archive/interface", "docs", "experiments", "src"}) {
      QVERIFY(QDir(fixture.path()).mkpath(path));
    }
    QFile file(fixture.filePath("archive/layout.md"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("layout fixture");
    file.close();
    QFile nestedFile(fixture.filePath("archive/interface/component.qml"));
    QVERIFY(nestedFile.open(QIODevice::WriteOnly));
    nestedFile.write("import QtQuick\nItem {}\n");
    nestedFile.close();
    QQmlComponent component(engine.get());
    component.setData(R"(
      import QtQuick
      import T3.Bricks
      Window {
        id: window
        width: 900; height: 900; visible: true
        property string directory
        FolderExplorer { anchors.fill: parent; rootPath: window.directory }
      }
    )", QUrl::fromLocalFile(fixture.filePath("fixture.qml")));
    QVERIFY2(component.isReady(), qPrintable(component.errorString()));
    std::unique_ptr<QObject> root(component.createWithInitialProperties({{"directory", fixture.path()}}));
    QVERIFY2(root, qPrintable(component.errorString()));
    auto* tree = root->findChild<QQuickItem*>("folderTree");
    auto* model = root->findChild<LocalFolderModel*>("localFolderModel");
    QVERIFY(tree && model);
    auto visibleRows = [tree, &fixture] {
      QStringList rows;
      for (int row = 0; row < tree->property("rows").toInt(); ++row) {
        QQuickItem* delegate = nullptr;
        QMetaObject::invokeMethod(tree, "itemAtCell", Q_RETURN_ARG(QQuickItem*, delegate), Q_ARG(QPoint, QPoint(0, row)));
        if (!delegate) return QStringList{"not laid out"};
        rows.append(QDir(fixture.path()).relativeFilePath(delegate->property("filePath").toString()) +
                    ":" + delegate->property("depth").toString());
      }
      return rows;
    };
    QTRY_COMPARE(visibleRows(), (QStringList{"archive:0", "docs:0", "experiments:0", "src:0"}));
    QVERIFY(QMetaObject::invokeMethod(tree, "expand", Q_ARG(int, 0)));
    QTRY_COMPARE(tree->property("rows").toInt(), 6);
    QStringList indexedRows;
    for (int row = 0; row < 6; ++row) {
      QModelIndex index;
      QVERIFY(QMetaObject::invokeMethod(tree, "index", Q_RETURN_ARG(QModelIndex, index), Q_ARG(int, row), Q_ARG(int, 0)));
      indexedRows.append(QDir(fixture.path()).relativeFilePath(index.data(QFileSystemModel::FilePathRole).toString()));
    }
    QCOMPARE(indexedRows, (QStringList{"archive", "archive/interface", "archive/layout.md", "docs", "experiments", "src"}));
    QTRY_COMPARE(visibleRows(), (QStringList{"archive:0", "archive/interface:1", "archive/layout.md:1", "docs:0", "experiments:0", "src:0"}));

    QVERIFY(QMetaObject::invokeMethod(tree, "expand", Q_ARG(int, 1)));
    QTRY_COMPARE(visibleRows(), (QStringList{"archive:0", "archive/interface:1", "archive/interface/component.qml:2", "archive/layout.md:1", "docs:0", "experiments:0", "src:0"}));
    QVERIFY(QMetaObject::invokeMethod(tree, "collapse", Q_ARG(int, 1)));
    QTRY_COMPARE(visibleRows(), (QStringList{"archive:0", "archive/interface:1", "archive/layout.md:1", "docs:0", "experiments:0", "src:0"}));

    QCOMPARE(model->renameFolder(fixture.filePath("archive/interface"), "design"), fixture.filePath("archive/design"));
    QTRY_COMPARE(visibleRows(), (QStringList{"archive:0", "archive/design:1", "archive/layout.md:1", "docs:0", "experiments:0", "src:0"}));
    QCOMPARE(model->moveFolder(fixture.filePath("archive/design"), fixture.filePath("docs")), fixture.filePath("docs/design"));
    QTRY_COMPARE(visibleRows(), (QStringList{"archive:0", "archive/layout.md:1", "docs:0", "experiments:0", "src:0"}));
    QVERIFY(QMetaObject::invokeMethod(tree, "expand", Q_ARG(int, 2)));
    QTRY_COMPARE(visibleRows(), (QStringList{"archive:0", "archive/layout.md:1", "docs:0", "docs/design:1", "experiments:0", "src:0"}));
    QCOMPARE(model->createFolder(fixture.filePath("archive"), "drafts"), fixture.filePath("archive/drafts"));
    QTRY_COMPARE(visibleRows(), (QStringList{"archive:0", "archive/drafts:1", "archive/layout.md:1", "docs:0", "docs/design:1", "experiments:0", "src:0"}));
    QVERIFY(QMetaObject::invokeMethod(tree, "collapse", Q_ARG(int, 0)));
    QTRY_COMPARE(visibleRows(), (QStringList{"archive:0", "docs:0", "docs/design:1", "experiments:0", "src:0"}));
    QVERIFY(QMetaObject::invokeMethod(tree, "collapse", Q_ARG(int, 1)));
    QTRY_COMPARE(visibleRows(), (QStringList{"archive:0", "docs:0", "experiments:0", "src:0"}));
  }

  void cleanupTestCase() {
    engine.reset();
    theme.reset();
  }
};

int main(int argc, char** argv) {
  QGuiApplication app(argc, argv);
  app.setQuitOnLastWindowClosed(false);
  FolderExplorerTest test;
  return QTest::qExec(&test, argc, argv);
}
#include "tst_FolderExplorer.moc"
