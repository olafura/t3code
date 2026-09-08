#pragma once

#include <QFileSystemModel>

// Local, trusted QML only. The hosted page has no filesystem mutation API.
class LocalFolderModel : public QFileSystemModel {
  Q_OBJECT
  Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
  Q_PROPERTY(QString rootPath READ browseRootPath WRITE setBrowseRootPath NOTIFY rootChanged)
  Q_PROPERTY(QModelIndex rootIndex READ rootIndex NOTIFY rootChanged)
  Q_PROPERTY(QStringList protectedPaths READ protectedPaths WRITE setProtectedPaths NOTIFY protectedPathsChanged)
  Q_PROPERTY(QString error READ error NOTIFY errorChanged)

public:
  enum Roles { IsDirectoryRole = Qt::UserRole + 4 };
  Q_ENUM(Roles)

  explicit LocalFolderModel(QObject* parent = nullptr);
  bool enabled() const { return m_enabled; }
  void setEnabled(bool enabled);
  QString browseRootPath() const { return m_rootPath; }
  void setBrowseRootPath(const QString& path);
  QModelIndex rootIndex() const;
  QStringList protectedPaths() const { return m_protectedPaths; }
  void setProtectedPaths(const QStringList& paths);
  QString error() const { return m_error; }

  Q_INVOKABLE QString pathForIndex(const QModelIndex& index) const;
  Q_INVOKABLE bool isDirectory(const QString& path) const;
  Q_INVOKABLE bool canModifyFolder(const QString& path) const;
  Q_INVOKABLE QString createFolder(const QString& parentPath, const QString& name);
  Q_INVOKABLE QString renameFolder(const QString& path, const QString& newName);
  Q_INVOKABLE QString moveFolder(const QString& path, const QString& destinationDirectory);
  Q_INVOKABLE bool trashFolder(const QString& path, const QString& confirmationPath);

  int rowCount(const QModelIndex& parent = {}) const override;
  bool hasChildren(const QModelIndex& parent = {}) const override;
  bool canFetchMore(const QModelIndex& parent) const override;
  void fetchMore(const QModelIndex& parent) override;
  QHash<int, QByteArray> roleNames() const override;
  QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override;
  bool setData(const QModelIndex&, const QVariant&, int = Qt::EditRole) override { return false; }
  bool dropMimeData(const QMimeData*, Qt::DropAction, int, int, const QModelIndex&) override { return false; }
  Qt::ItemFlags flags(const QModelIndex& index) const override;

signals:
  void enabledChanged();
  void rootChanged();
  void protectedPathsChanged();
  void errorChanged();

private:
  void activateRoot();
  void setError(const QString& error);
  QString checkedDirectory(const QString& path, bool allowRoot);
  bool validName(const QString& name);
  bool canRelocate(const QString& path);
  bool containsProject(const QString& path) const;
  QString relocate(const QString& source, const QString& destination);

  bool m_enabled = false;
  QString m_rootPath;
  QStringList m_protectedPaths;
  QString m_error;
};
