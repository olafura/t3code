#include "NativeNotifications.h"

#ifdef T3_HAS_DBUS
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusServiceWatcher>
#endif

namespace {
#ifdef T3_HAS_DBUS
const QString service = QStringLiteral("org.freedesktop.Notifications");
const QString path = QStringLiteral("/org/freedesktop/Notifications");

void closeNotification(const QString& owner, uint id) {
  auto message = QDBusMessage::createMethodCall(owner, path, service, QStringLiteral("CloseNotification"));
  message << id;
  QDBusConnection::sessionBus().asyncCall(message);
}
#endif
}

NativeNotifications::NativeNotifications(QObject* parent) : QObject(parent) {
#ifdef T3_HAS_DBUS
  auto bus = QDBusConnection::sessionBus();
  bus.connect(service, path, service, QStringLiteral("ActionInvoked"), this,
              SLOT(notificationAction(uint,QString,QDBusMessage)));
  bus.connect(service, path, service, QStringLiteral("NotificationClosed"), this,
              SLOT(notificationClosed(uint,uint,QDBusMessage)));
  auto* watcher = new QDBusServiceWatcher(service, bus, QDBusServiceWatcher::WatchForOwnerChange, this);
  connect(watcher, &QDBusServiceWatcher::serviceOwnerChanged, this, &NativeNotifications::refreshSupport);
#endif
  refreshSupport();
}

NativeNotifications::~NativeNotifications() {
  closeAll();
}

void NativeNotifications::refreshSupport() {
  bool supported = false;
#ifdef T3_HAS_DBUS
  const auto bus = QDBusConnection::sessionBus();
  const QString owner = bus.isConnected() ? bus.interface()->serviceOwner(service).value() : QString();
  if (m_serviceOwner != owner) {
    ++m_generation;
    m_notifications.clear();
    m_serviceOwner = owner;
  }
  supported = !owner.isEmpty();
#endif
  if (m_supported == supported) return;
  m_supported = supported;
  emit supportedChanged();
}

void NativeNotifications::setEnabled(bool enabled) {
  if (m_enabled == enabled) return;
  m_enabled = enabled;
  ++m_generation;
  if (!enabled) closeAll();
  emit enabledChanged();
}

void NativeNotifications::setError(const QString& error) {
  if (m_lastError == error) return;
  m_lastError = error;
  emit lastErrorChanged();
}

bool NativeNotifications::show(const QString& key, const QString& title, const QString& body,
                                bool silent, int timeoutMs) {
  if (!m_enabled || key.isEmpty()) return false;
  if (!m_supported) {
    setError(tr("Native notifications require a Linux desktop notification service."));
    return false;
  }
#ifdef T3_HAS_DBUS
  // A notification ID belongs to one daemon, not its reusable well-known
  // service name. Pin requests and delayed cleanup to that unique owner.
  const QString owner = m_serviceOwner;
  auto message = QDBusMessage::createMethodCall(owner, path, service, QStringLiteral("Notify"));
  message << QStringLiteral("T3 Code") << m_notifications.key(key, 0u)
          << QStringLiteral("t3code") << title << body.toHtmlEscaped()
          << QStringList{QStringLiteral("default"), tr("Open thread")}
          << QVariantMap{{QStringLiteral("desktop-entry"), QStringLiteral("t3code")},
                         {QStringLiteral("suppress-sound"), silent}}
          << qMax(-1, timeoutMs);
  auto* pending = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(message), this);
  connect(pending, &QDBusPendingCallWatcher::finished, this, [this, key, owner, generation = m_generation](QDBusPendingCallWatcher* call) {
    QDBusPendingReply<uint> reply = *call;
    call->deleteLater();
    if (reply.isError()) {
      setError(reply.error().message());
      return;
    }
    if (!m_enabled || generation != m_generation) {
      closeNotification(owner, reply.value());
      return;
    }
    m_notifications.insert(reply.value(), key);
    setError({});
  });
  return true;
#else
  Q_UNUSED(title)
  Q_UNUSED(body)
  Q_UNUSED(silent)
  Q_UNUSED(timeoutMs)
  return false;
#endif
}

#ifdef T3_HAS_DBUS
void NativeNotifications::notificationAction(uint id, const QString& action, const QDBusMessage& message) {
  if (message.service() == m_serviceOwner && m_enabled && action == QStringLiteral("default") && m_notifications.contains(id)) {
    emit activated(m_notifications.value(id));
  }
}

void NativeNotifications::notificationClosed(uint id, uint reason, const QDBusMessage& message) {
  Q_UNUSED(reason)
  if (message.service() == m_serviceOwner) m_notifications.remove(id);
}
#endif

void NativeNotifications::closeAll() {
#ifdef T3_HAS_DBUS
  for (const auto id : m_notifications.keys()) closeNotification(m_serviceOwner, id);
#endif
  m_notifications.clear();
}
