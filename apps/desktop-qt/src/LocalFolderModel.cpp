#include "LocalFolderModel.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>

namespace {

bool within(const QString& path, const QString& root) {
#ifdef Q_OS_WIN
  return path.compare(root, Qt::CaseInsensitive) == 0 || path.startsWith(root + QLatin1Char('/'), Qt::CaseInsensitive);
#else
  return path == root || path.startsWith(root + QLatin1Char('/'));
#endif
}

// Validate every component before canonicalizing; canonicalization alone would
// hide a symlink that escapes the user's selected directory.
QString plainEntry(const QString& path, bool directoryOnly) {
  if (path.isEmpty() || path.contains(QChar::Null) || !QDir::isAbsolutePath(path)) return {};
  const auto nativePath = QDir::fromNativeSeparators(path);
  for (const auto& part : nativePath.split(QLatin1Char('/'), Qt::SkipEmptyParts)) {
    if (part == QLatin1String(".") || part == QLatin1String("..")) return {};
  }
  const QFileInfo info(nativePath);
  if (!info.exists() || (!info.isDir() && (directoryOnly || !info.isFile()))) return {};
  auto current = QDir::cleanPath(nativePath);
  while (true) {
    const QFileInfo component(current);
    if (component.isSymLink() || component.isJunction()) return {};
    const auto parent = component.absolutePath();
    if (parent == current) break;
    current = parent;
  }
  return info.canonicalFilePath();
}

QString plainDirectory(const QString& path) {
  return plainEntry(path, true);
}

bool broadDirectory(const QString& path) {
  const auto home = QFileInfo(QDir::homePath()).canonicalFilePath();
  return QFileInfo(path).isRoot() || (within(path, home) && within(home, path));
}

bool occupied(const QString& path) {
  const QFileInfo info(path);
  return info.exists() || info.isSymLink() || info.isJunction();
}

}  // namespace

LocalFolderModel::LocalFolderModel(QObject* parent) : QFileSystemModel(parent) {
  setOptions(DontWatchForChanges | DontResolveSymlinks | DontUseCustomDirectoryIcons);
  setReadOnly(true);
  setFilter(QDir::Dirs | QDir::Files | QDir::NoDotAndDotDot | QDir::NoSymLinks);
}

void LocalFolderModel::setEnabled(bool enabled) {
  if (m_enabled == enabled) return;
  beginResetModel();
  m_enabled = enabled;
  endResetModel();
  setOption(DontWatchForChanges, !enabled);
  if (enabled) activateRoot();
  emit enabledChanged();
  emit rootChanged();
}

void LocalFolderModel::setBrowseRootPath(const QString& path) {
  setError({});
  const auto directory = path.isEmpty() ? QString() : plainDirectory(path);
  if (!path.isEmpty() && (directory.isEmpty() || broadDirectory(directory))) {
    setError(tr("Choose an existing local folder other than your home or a filesystem root. Symlinks are not supported."));
    if (m_rootPath.isEmpty()) return;
    m_rootPath.clear();
  } else {
    if (m_rootPath == directory) return;
    m_rootPath = directory;
  }
  if (m_enabled) activateRoot();
  emit rootChanged();
}

void LocalFolderModel::activateRoot() {
  if (m_rootPath.isEmpty()) return;
  if (plainDirectory(m_rootPath).isEmpty()) {
    m_rootPath.clear();
    setError(tr("The selected root is no longer a plain local folder."));
    return;
  }
  QFileSystemModel::setRootPath(m_rootPath);
}

QModelIndex LocalFolderModel::rootIndex() const {
  return m_enabled && !m_rootPath.isEmpty() ? index(m_rootPath) : QModelIndex();
}

void LocalFolderModel::setProtectedPaths(const QStringList& paths) {
  if (m_protectedPaths == paths) return;
  m_protectedPaths = paths;
  emit protectedPathsChanged();
}

void LocalFolderModel::setError(const QString& error) {
  if (m_error == error) return;
  m_error = error;
  emit errorChanged();
}

int LocalFolderModel::rowCount(const QModelIndex& parent) const {
  return m_enabled && !m_rootPath.isEmpty() ? QFileSystemModel::rowCount(parent) : 0;
}

bool LocalFolderModel::hasChildren(const QModelIndex& parent) const {
  return m_enabled && !m_rootPath.isEmpty() && QFileSystemModel::hasChildren(parent);
}

bool LocalFolderModel::canFetchMore(const QModelIndex& parent) const {
  return m_enabled && !m_rootPath.isEmpty() && QFileSystemModel::canFetchMore(parent);
}

void LocalFolderModel::fetchMore(const QModelIndex& parent) {
  if (m_enabled && !m_rootPath.isEmpty()) QFileSystemModel::fetchMore(parent);
}

Qt::ItemFlags LocalFolderModel::flags(const QModelIndex& index) const {
  return QFileSystemModel::flags(index) & ~(Qt::ItemIsEditable | Qt::ItemIsDropEnabled | Qt::ItemIsDragEnabled);
}

QHash<int, QByteArray> LocalFolderModel::roleNames() const {
  auto roles = QFileSystemModel::roleNames();
  roles.insert(IsDirectoryRole, "isDirectory");
  return roles;
}

QVariant LocalFolderModel::data(const QModelIndex& candidate, int role) const {
  if (role == IsDirectoryRole) {
    return m_enabled && !m_rootPath.isEmpty() && candidate.isValid() &&
        candidate.model() == this && within(filePath(candidate), m_rootPath) && isDir(candidate);
  }
  return QFileSystemModel::data(candidate, role);
}

QString LocalFolderModel::pathForIndex(const QModelIndex& candidate) const {
  if (!m_enabled || m_rootPath.isEmpty() || !candidate.isValid() || candidate.model() != this) return {};
  const auto path = plainEntry(filePath(candidate), false);
  return !path.isEmpty() && within(path, m_rootPath) ? path : QString();
}

bool LocalFolderModel::isDirectory(const QString& path) const {
  if (!m_enabled || m_rootPath.isEmpty()) return false;
  const auto directory = plainDirectory(path);
  return !directory.isEmpty() && within(directory, m_rootPath);
}

QString LocalFolderModel::checkedDirectory(const QString& path, bool allowRoot) {
  if (!m_enabled || m_rootPath.isEmpty()) {
    setError(tr("Local folder access is disabled or no root folder is selected."));
    return {};
  }
  const auto root = plainDirectory(m_rootPath);
  const auto directory = plainDirectory(path);
  if (root.isEmpty() || directory.isEmpty() || broadDirectory(directory) || !within(directory, root) || (!allowRoot && within(root, directory))) {
    setError(tr("Choose a plain folder inside the selected root. The root itself, home, symlinks and outside paths cannot be changed."));
    return {};
  }
  return directory;
}

bool LocalFolderModel::validName(const QString& name) {
  if (name.isEmpty() || name != name.trimmed() || name == QLatin1String(".") || name == QLatin1String("..") || name.contains(QLatin1Char('/')) || name.contains(QLatin1Char('\\')) || name.contains(QChar::Null)) {
    setError(tr("Enter one folder name, without path separators or leading/trailing whitespace."));
    return false;
  }
  return true;
}

bool LocalFolderModel::containsProject(const QString& path) const {
  for (const auto& protectedPath : m_protectedPaths) {
    if (!QDir::isAbsolutePath(protectedPath)) continue;
    const QFileInfo info(protectedPath);
    const auto lexical = QDir::cleanPath(QDir::fromNativeSeparators(protectedPath));
    const auto canonical = info.canonicalFilePath();
    if (within(lexical, path) || (!canonical.isEmpty() && within(canonical, path))) {
      return true;
    }
  }
  return false;
}

bool LocalFolderModel::canModifyFolder(const QString& path) const {
  if (!m_enabled || m_rootPath.isEmpty()) return false;
  const auto root = plainDirectory(m_rootPath);
  const auto directory = plainDirectory(path);
  return !root.isEmpty() && !directory.isEmpty() && !broadDirectory(directory) &&
      !within(root, directory) && within(directory, root) && !containsProject(directory);
}

bool LocalFolderModel::canRelocate(const QString& path) {
  if (!containsProject(path)) return true;
  setError(tr("This folder contains a registered project. Its location is protected because threads may still use that path."));
  return false;
}

QString LocalFolderModel::createFolder(const QString& parentPath, const QString& name) {
  setError({});
  const auto parent = checkedDirectory(parentPath, true);
  if (parent.isEmpty() || !validName(name)) return {};
  const auto destination = QDir(parent).filePath(name);
  if (occupied(destination)) {
    setError(tr("A file or folder already exists with that name."));
    return {};
  }
  if (!QDir(parent).mkdir(name)) {
    setError(tr("The folder could not be created. Check permissions."));
    return {};
  }
  return destination;
}

QString LocalFolderModel::relocate(const QString& source, const QString& destination) {
  if (occupied(destination)) {
    setError(tr("The destination already exists. Nothing was overwritten."));
    return {};
  }
  if (!QDir().rename(source, destination)) {
    setError(tr("The folder could not be moved. Check permissions and keep it on the same filesystem."));
    return {};
  }
  return destination;
}

QString LocalFolderModel::renameFolder(const QString& path, const QString& newName) {
  setError({});
  const auto source = checkedDirectory(path, false);
  if (source.isEmpty() || !validName(newName) || !canRelocate(source)) return {};
  return relocate(source, QDir(QFileInfo(source).absolutePath()).filePath(newName));
}

QString LocalFolderModel::moveFolder(const QString& path, const QString& destinationDirectory) {
  setError({});
  const auto source = checkedDirectory(path, false);
  if (source.isEmpty() || !canRelocate(source)) return {};
  const auto parent = checkedDirectory(destinationDirectory, true);
  if (parent.isEmpty()) return {};
  if (within(parent, source)) {
    setError(tr("A folder cannot be moved into itself or one of its descendants."));
    return {};
  }
  return relocate(source, QDir(parent).filePath(QFileInfo(source).fileName()));
}

bool LocalFolderModel::trashFolder(const QString& path, const QString& confirmationPath) {
  setError({});
  const auto source = checkedDirectory(path, false);
  if (source.isEmpty() || !canRelocate(source)) return false;
  if (confirmationPath != source) {
    setError(tr("Confirm by entering the exact full folder path."));
    return false;
  }
  if (!QFile::moveToTrash(source)) {
    setError(tr("The folder could not be moved to the system trash. It has not been permanently deleted."));
    return false;
  }
  return true;
}
