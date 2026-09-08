#pragma once

#include <QHash>
#include <QObject>
#ifdef T3_HAS_DBUS
#include <QDBusMessage>
#endif

// Opt-in OS delivery. Linux uses notification IDs so an older toast always
// opens its own thread, even after newer notifications have been delivered.
class NativeNotifications : public QObject {
  Q_OBJECT
  Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
  Q_PROPERTY(bool supported READ supported NOTIFY supportedChanged)
  Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
  explicit NativeNotifications(QObject* parent = nullptr);
  ~NativeNotifications() override;
  bool enabled() const { return m_enabled; }
  void setEnabled(bool enabled);
  bool supported() const { return m_supported; }
  QString lastError() const { return m_lastError; }
  Q_INVOKABLE bool show(const QString& key, const QString& title, const QString& body,
                        bool silent = false, int timeoutMs = -1);

signals:
  void enabledChanged();
  void supportedChanged();
  void lastErrorChanged();
  void activated(const QString& key);

private slots:
#ifdef T3_HAS_DBUS
  void notificationAction(uint id, const QString& action, const QDBusMessage& message);
  void notificationClosed(uint id, uint reason, const QDBusMessage& message);
#endif
  void refreshSupport();

private:
  void closeAll();
  void setError(const QString& error);
  bool m_enabled = false;
  bool m_supported = false;
  uint m_generation = 0;
  QString m_lastError;
  QString m_serviceOwner;
  QHash<uint, QString> m_notifications;
};
