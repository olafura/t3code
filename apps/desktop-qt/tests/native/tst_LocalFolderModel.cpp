#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QMimeData>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>

#include "LocalFolderModel.h"

class LocalFolderModelTest : public QObject {
  Q_OBJECT

private slots:
  void disabledDoesNotBrowseOrMutate() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    LocalFolderModel model;
    QSignalSpy loaded(&model, &QFileSystemModel::directoryLoaded);
    model.setBrowseRootPath(directory.path());
    QVERIFY(!model.enabled());
    QVERIFY(!model.rootIndex().isValid());
    QCOMPARE(model.rowCount(), 0);
    QVERIFY(!model.canFetchMore({}));
    QVERIFY(model.createFolder(directory.path(), "no").isEmpty());
    QCOMPARE(loaded.size(), 0);
    QVERIFY(!QFileInfo::exists(directory.filePath("no")));
  }

  void browseLoadsFilesAndFoldersAndDisablingHidesThem() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QVERIFY(QDir(directory.path()).mkdir("child"));
    QFile file(directory.filePath("plain-file"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.close();
    LocalFolderModel model;
    model.setBrowseRootPath(directory.path());
    model.setEnabled(true);
    QVERIFY(model.rootIndex().isValid());
    QTRY_COMPARE(model.rowCount(model.rootIndex()), 2);
    const auto child = model.index(directory.filePath("child"));
    const auto fileIndex = model.index(file.fileName());
    QCOMPARE(model.pathForIndex(child), directory.filePath("child"));
    QCOMPARE(model.pathForIndex(fileIndex), file.fileName());
    QCOMPARE(model.data(child, QFileSystemModel::FileNameRole).toString(), QString("child"));
    QCOMPARE(model.roleNames().value(LocalFolderModel::IsDirectoryRole), QByteArray("isDirectory"));
    QCOMPARE(model.data(child, LocalFolderModel::IsDirectoryRole).toBool(), true);
    QCOMPARE(model.data(fileIndex, LocalFolderModel::IsDirectoryRole).toBool(), false);
    QVERIFY(model.isDirectory(directory.path()));
    QVERIFY(model.isDirectory(directory.filePath("child")));
    QVERIFY(!model.isDirectory(file.fileName()));
    model.setEnabled(false);
    QVERIFY(!model.rootIndex().isValid());
    QCOMPARE(model.rowCount(child), 0);
    QVERIFY(model.pathForIndex(child).isEmpty());
    QVERIFY(model.pathForIndex(fileIndex).isEmpty());
    QVERIFY(!model.isDirectory(directory.path()));
    QCOMPARE(model.data(child, LocalFolderModel::IsDirectoryRole).toBool(), false);
  }

  void displayedFilesRemainReadOnlyAndPathsStayInsideRoot() {
    QTemporaryDir directory;
    QTemporaryDir outside;
    QVERIFY(directory.isValid() && outside.isValid());
    QFile file(directory.filePath("example.txt"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    QCOMPARE(file.write("do not change"), 13);
    file.close();
    QFile outsideFile(outside.filePath("outside.txt"));
    QVERIFY(outsideFile.open(QIODevice::WriteOnly));
    outsideFile.close();
    LocalFolderModel model;
    model.setBrowseRootPath(directory.path());
    model.setEnabled(true);
    QTRY_COMPARE(model.rowCount(model.rootIndex()), 1);
    const auto fileIndex = model.index(file.fileName());
    QVERIFY(!model.canModifyFolder(file.fileName()));
    QVERIFY(model.createFolder(file.fileName(), "child").isEmpty());
    QVERIFY(model.renameFolder(file.fileName(), "renamed.txt").isEmpty());
    QVERIFY(model.moveFolder(file.fileName(), directory.path()).isEmpty());
    QVERIFY(!model.trashFolder(file.fileName(), file.fileName()));
    QVERIFY(!model.setData(fileIndex, "renamed.txt", Qt::EditRole));
    QVERIFY(model.pathForIndex(model.index(outsideFile.fileName())).isEmpty());
    QVERIFY(!model.isDirectory(outside.path()));
    QVERIFY(!model.isDirectory(directory.filePath("../")));
#ifdef Q_OS_UNIX
    const auto link = directory.filePath("linked-file");
    const auto directoryLink = directory.filePath("linked-directory");
    QVERIFY(QFile::link(file.fileName(), link));
    QVERIFY(QFile::link(outside.path(), directoryLink));
    QVERIFY(model.pathForIndex(model.index(link)).isEmpty());
    QVERIFY(model.pathForIndex(model.index(directoryLink + "/outside.txt")).isEmpty());
    QVERIFY(!model.isDirectory(directoryLink));
#endif
    LocalFolderModel other;
    other.setBrowseRootPath(directory.path());
    other.setEnabled(true);
    QVERIFY(model.pathForIndex(other.index(file.fileName())).isEmpty());
    QVERIFY(file.open(QIODevice::ReadOnly));
    QCOMPARE(file.readAll(), QByteArray("do not change"));
  }

  void createRenameAndMovePreserveContents() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    LocalFolderModel model;
    model.setBrowseRootPath(directory.path());
    model.setEnabled(true);
    const auto source = model.createFolder(directory.path(), QString::fromUtf8("新 folder"));
    QCOMPARE(source, directory.filePath(QString::fromUtf8("新 folder")));
    QFile marker(QDir(source).filePath("keep.txt"));
    QVERIFY(marker.open(QIODevice::WriteOnly));
    QCOMPARE(marker.write("preserved"), 9);
    marker.close();
    const auto renamed = model.renameFolder(source, "renamed");
    QCOMPARE(renamed, directory.filePath("renamed"));
    QVERIFY(!QFileInfo::exists(source));
    const auto destination = model.createFolder(directory.path(), "destination");
    const auto moved = model.moveFolder(renamed, destination);
    QCOMPARE(moved, directory.filePath("destination/renamed"));
    QFile retained(QDir(moved).filePath("keep.txt"));
    QVERIFY(retained.open(QIODevice::ReadOnly));
    QCOMPARE(retained.readAll(), QByteArray("preserved"));
    QVERIFY(model.error().isEmpty());
  }

  void namesAndCollisionsNeverOverwrite() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    LocalFolderModel model;
    model.setBrowseRootPath(directory.path());
    model.setEnabled(true);
    const auto a = model.createFolder(directory.path(), "a");
    const auto b = model.createFolder(directory.path(), "b");
    QVERIFY(!a.isEmpty() && !b.isEmpty());
    for (const auto& name : {QString(), QString("."), QString(".."), QString("x/y"), QString("x\\y"), QString(" x"), QString("x "), QString(QChar::Null)}) {
      QVERIFY(model.createFolder(directory.path(), name).isEmpty());
      QVERIFY(model.renameFolder(a, name).isEmpty());
    }
    QVERIFY(model.createFolder(directory.path(), "a").isEmpty());
    QVERIFY(model.renameFolder(a, "b").isEmpty());
    QVERIFY(model.moveFolder(a, directory.path()).isEmpty());
    QCOMPARE(model.createFolder(b, "a"), directory.filePath("b/a"));
    QVERIFY(model.moveFolder(a, b).isEmpty());
    QFile existing(directory.filePath("file"));
    QVERIFY(existing.open(QIODevice::WriteOnly));
    existing.write("keep");
    existing.close();
    QVERIFY(model.createFolder(directory.path(), "file").isEmpty());
    QVERIFY(model.renameFolder(a, "file").isEmpty());
#ifdef Q_OS_UNIX
    QVERIFY(QFile::link(directory.filePath("missing-target"), directory.filePath("dangling")));
    QVERIFY(model.createFolder(directory.path(), "dangling").isEmpty());
    QVERIFY(model.renameFolder(a, "dangling").isEmpty());
#endif
    QVERIFY(QFileInfo(a).isDir());
    QVERIFY(QFileInfo(b).isDir());
    QVERIFY(QFileInfo(directory.filePath("b/a")).isDir());
  }

  void rejectsRootsOutsideFilesSymlinksAndSelfMoves() {
    QTemporaryDir directory;
    QTemporaryDir outside;
    QVERIFY(directory.isValid() && outside.isValid());
    LocalFolderModel model;
    model.setBrowseRootPath(directory.path());
    model.setEnabled(true);
    const auto a = model.createFolder(directory.path(), "a");
    const auto child = model.createFolder(a, "child");
    QVERIFY(model.renameFolder(directory.path(), "changed").isEmpty());
    QVERIFY(model.createFolder(outside.path(), "escape").isEmpty());
    QVERIFY(model.moveFolder(a, outside.path()).isEmpty());
    QVERIFY(model.moveFolder(a, a).isEmpty());
    QVERIFY(model.moveFolder(a, child).isEmpty());
    QVERIFY(model.createFolder(directory.filePath("a/../a"), "escape").isEmpty());
    QFile file(directory.filePath("plain-file"));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.close();
    QVERIFY(model.renameFolder(file.fileName(), "not-a-folder").isEmpty());
#ifdef Q_OS_UNIX
    const auto link = directory.filePath("link");
    QVERIFY(QFile::link(outside.path(), link));
    QVERIFY(model.createFolder(link, "escape").isEmpty());
    QVERIFY(model.renameFolder(link, "renamed-link").isEmpty());
    QVERIFY(model.trashFolder(link, link) == false);
    model.setBrowseRootPath(link);
    QVERIFY(model.browseRootPath().isEmpty());
#endif
    model.setBrowseRootPath(QDir::rootPath());
    QVERIFY(model.browseRootPath().isEmpty());
    model.setBrowseRootPath(QDir::homePath());
    QVERIFY(model.browseRootPath().isEmpty());
    QVERIFY(!QFileInfo::exists(outside.filePath("escape")));
  }

  void rechecksRootWhenItHasBeenReplacedByASymlink() {
#ifdef Q_OS_UNIX
    QTemporaryDir directory;
    QTemporaryDir outside;
    QVERIFY(directory.isValid() && outside.isValid());
    const auto selectedRoot = directory.filePath("selected-root");
    QVERIFY(QDir().mkdir(selectedRoot));
    LocalFolderModel model;
    model.setBrowseRootPath(selectedRoot);
    model.setEnabled(true);
    QVERIFY(QDir().rename(selectedRoot, directory.filePath("original-root")));
    QVERIFY(QFile::link(outside.path(), selectedRoot));
    QVERIFY(model.createFolder(selectedRoot, "escape").isEmpty());
    QVERIFY(!model.canModifyFolder(selectedRoot));
    QVERIFY(!QFileInfo::exists(outside.filePath("escape")));
    model.setEnabled(false);
    model.setEnabled(true);
    QVERIFY(model.browseRootPath().isEmpty());
    QVERIFY(!model.rootIndex().isValid());
#else
    QSKIP("Directory symlink fixture uses POSIX link semantics.");
#endif
  }

  void protectsProjectRootsAndAncestorsButAllowsOrdinaryChildren() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    LocalFolderModel model;
    model.setBrowseRootPath(directory.path());
    model.setEnabled(true);
    const auto parent = model.createFolder(directory.path(), "parent");
    const auto project = model.createFolder(parent, "project");
    const auto child = model.createFolder(project, "ordinary-child");
    model.setProtectedPaths({project});
    QVERIFY(!model.canModifyFolder(parent));
    QVERIFY(!model.canModifyFolder(project));
    QVERIFY(model.canModifyFolder(child));
    QVERIFY(model.renameFolder(parent, "elsewhere").isEmpty());
    QVERIFY(model.moveFolder(project, directory.path()).isEmpty());
    QVERIFY(!model.trashFolder(parent, parent));
    const auto error = model.error();
    QVERIFY(!error.isEmpty());
    QVERIFY(!model.canModifyFolder(project));
    QCOMPARE(model.error(), error);
    QCOMPARE(model.renameFolder(child, "safe"), QDir(project).filePath("safe"));
    model.setProtectedPaths({});
    QVERIFY(model.canModifyFolder(project));
    QCOMPARE(model.renameFolder(project, "unregistered"), QDir(parent).filePath("unregistered"));
  }

  void modelEditAndDropCannotBypassGuards() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    LocalFolderModel model;
    model.setBrowseRootPath(directory.path());
    model.setEnabled(true);
    const auto child = model.createFolder(directory.path(), "child");
    QTRY_COMPARE(model.rowCount(model.rootIndex()), 1);
    const auto index = model.index(0, 0, model.rootIndex());
    QVERIFY(model.isReadOnly());
    // Even trusted QML changing the inherited readOnly property cannot turn
    // generic model edits into an unguarded mutation path.
    model.setReadOnly(false);
    QVERIFY(!model.setData(index, "bypass", Qt::EditRole));
    QVERIFY(!(model.flags(index) & Qt::ItemIsEditable));
    QMimeData mime;
    QVERIFY(!model.dropMimeData(&mime, Qt::MoveAction, 0, 0, model.rootIndex()));
    QVERIFY(QFileInfo(child).isDir());
  }

  void trashRequiresExactConfirmationAndPreservesRecoverability() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto previousDataHome = qgetenv("XDG_DATA_HOME");
    const auto trashHome = directory.filePath("isolated-data");
    QVERIFY(QDir().mkpath(trashHome));
    qputenv("XDG_DATA_HOME", trashHome.toUtf8());
    LocalFolderModel model;
    model.setBrowseRootPath(directory.path());
    model.setEnabled(true);
    const auto victim = model.createFolder(directory.path(), "discarded-test-folder");
    QFile marker(QDir(victim).filePath("keep.txt"));
    QVERIFY(marker.open(QIODevice::WriteOnly));
    marker.write("recover me");
    marker.close();
    QVERIFY(!model.trashFolder(victim, "discarded-test-folder"));
    QVERIFY(QFileInfo(victim).isDir());
    const bool trashed = model.trashFolder(victim, victim);
    if (trashed) {
      QVERIFY(!QFileInfo::exists(victim));
#ifdef Q_OS_LINUX
      const auto files = QDir(trashHome + "/Trash/files").entryList(QDir::Dirs | QDir::NoDotAndDotDot);
      QCOMPARE(files.size(), 1);
      QFile recovered(trashHome + "/Trash/files/" + files.first() + "/keep.txt");
      QVERIFY(recovered.open(QIODevice::ReadOnly));
      QCOMPARE(recovered.readAll(), QByteArray("recover me"));
#endif
    } else {
      QVERIFY(QFileInfo(QDir(victim).filePath("keep.txt")).isFile());
      QVERIFY(!model.error().isEmpty());
    }
    if (previousDataHome.isNull()) qunsetenv("XDG_DATA_HOME");
    else qputenv("XDG_DATA_HOME", previousDataHome);
  }

  void qmlConfigurationUsesTheNativeModel() {
    qmlRegisterType<LocalFolderModel>("FolderTest", 1, 0, "LocalFolderModel");
    QQmlEngine engine;
    QQmlComponent component(&engine);
    component.setData("import FolderTest\nLocalFolderModel { enabled: false; protectedPaths: [\"/example/project\"] }", QUrl());
    std::unique_ptr<QObject> instance(component.create());
    QVERIFY2(instance, qPrintable(component.errorString()));
    auto* model = qobject_cast<LocalFolderModel*>(instance.get());
    QVERIFY(model);
    QCOMPARE(model->protectedPaths(), QStringList{"/example/project"});
    QCOMPARE(model->rowCount(), 0);
  }
};

int main(int argc, char** argv) {
  QGuiApplication app(argc, argv);
  LocalFolderModelTest test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_LocalFolderModel.moc"
