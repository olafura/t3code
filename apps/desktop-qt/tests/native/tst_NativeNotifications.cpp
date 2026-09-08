#include <QDBusConnection>
#include <QDBusContext>
#include <QSignalSpy>
#include <QTest>

#include "NativeNotifications.h"

class NotificationService : public QObject, protected QDBusContext {
  Q_OBJECT
  Q_CLASSINFO("D-Bus Interface", "org.freedesktop.Notifications")

public:
  uint nextId = 1;
  QList<uint> issued;
  QList<uint> closed;
  QString lastBody;
  QVariantMap lastHints;
  int lastTimeout = 0;
  bool delayNext = false;
  QDBusMessage pendingReply;

  void finishDelayedReply() {
    QDBusConnection::sessionBus().send(pendingReply);
    pendingReply = {};
  }

public slots:
  uint Notify(const QString&, uint replacesId, const QString&, const QString&,
              const QString& body, const QStringList&, const QVariantMap& hints, int timeout) {
    const uint id = replacesId ? replacesId : nextId++;
    issued.append(id);
    lastBody = body;
    lastHints = hints;
    lastTimeout = timeout;
    if (delayNext) {
      delayNext = false;
      setDelayedReply(true);
      pendingReply = message().createReply(QVariant::fromValue(id));
    }
    return id;
  }
  void CloseNotification(uint id) {
    closed.append(id);
    emit NotificationClosed(id, 3);
  }

signals:
  void ActionInvoked(uint id, const QString& action);
  void NotificationClosed(uint id, uint reason);
};

class NativeNotificationsTest : public QObject {
  Q_OBJECT
  NotificationService service;

private slots:
  void initTestCase() {
    auto bus = QDBusConnection::sessionBus();
    QVERIFY(bus.isConnected());
    QVERIFY(bus.registerService("org.freedesktop.Notifications"));
    QVERIFY(bus.registerObject("/org/freedesktop/Notifications", &service,
                               QDBusConnection::ExportAllSlots | QDBusConnection::ExportAllSignals));
  }

  void notificationsAreOptInAndClicksKeepTheirThread() {
    NativeNotifications notifications;
    QVERIFY(notifications.supported());
    QVERIFY(!notifications.show("thread-a", "Turn complete", "Done"));
    QCOMPARE(service.issued.size(), 0);
    notifications.setEnabled(true);
    QVERIFY(notifications.show("thread-a", "Turn complete", "<plain text>", true, 12000));
    QTRY_COMPARE(service.issued.size(), 1);
    const uint first = service.issued.last();
    QCOMPARE(service.lastBody, QString("&lt;plain text&gt;"));
    QCOMPARE(service.lastHints.value("suppress-sound").toBool(), true);
    QCOMPARE(service.lastTimeout, 12000);
    QVERIFY(notifications.show("thread-b", "Approval required", "Review the command"));
    QTRY_COMPARE(service.issued.size(), 2);
    const uint second = service.issued.last();
    QSignalSpy activated(&notifications, &NativeNotifications::activated);
    emit service.ActionInvoked(first, "default");
    QTRY_COMPARE(activated.size(), 1);
    QCOMPARE(activated.last().at(0).toString(), QString("thread-a"));
    emit service.ActionInvoked(second, "default");
    QTRY_COMPARE(activated.size(), 2);
    QCOMPARE(activated.last().at(0).toString(), QString("thread-b"));

    // Another update to one thread replaces only that thread's toast.
    QVERIFY(notifications.show("thread-a", "Approval required", "Choose an option"));
    QTRY_COMPARE(service.issued.size(), 3);
    QCOMPARE(service.issued.last(), first);
    notifications.setEnabled(false);
    QTRY_VERIFY(service.closed.contains(first));
    QTRY_VERIFY(service.closed.contains(second));
    emit service.ActionInvoked(first, "default");
    // Round-trip a service call so queued signals have been delivered.
    notifications.setEnabled(true);
    QVERIFY(notifications.show("thread-c", "Complete", "Done"));
    QTRY_COMPARE(service.issued.size(), 4);
    QCOMPARE(activated.size(), 2);
  }

  void disablingFencesDeliveryRepliesAlreadyInFlight() {
    NativeNotifications notifications;
    notifications.setEnabled(true);
    const auto issuedBefore = service.issued.size();
    QVERIFY(notifications.show("stale-thread", "Complete", "Done"));
    notifications.setEnabled(false);
    notifications.setEnabled(true);
    QTRY_COMPARE(service.issued.size(), issuedBefore + 1);
    const uint staleId = service.issued.last();
    QTRY_VERIFY(service.closed.contains(staleId));
    QSignalSpy activated(&notifications, &NativeNotifications::activated);
    emit service.ActionInvoked(staleId, "default");
    QVERIFY(notifications.show("new-thread", "Complete", "Done"));
    QTRY_COMPARE(service.issued.size(), issuedBefore + 2);
    QCOMPARE(activated.size(), 0);
  }

  void lateRepliesCannotCloseAReplacementDaemonsNotification() {
    NativeNotifications notifications;
    notifications.setEnabled(true);
    const auto issuedBefore = service.issued.size();
    service.delayNext = true;
    QVERIFY(notifications.show("old-thread", "Complete", "Done"));
    QTRY_COMPARE(service.issued.size(), issuedBefore + 1);
    const uint oldId = service.issued.last();

    auto originalBus = QDBusConnection::sessionBus();
    QVERIFY(originalBus.unregisterService("org.freedesktop.Notifications"));
    QTRY_VERIFY(!notifications.supported());
    auto replacementBus = QDBusConnection::connectToBus(QDBusConnection::SessionBus, "replacement-daemon");
    NotificationService replacement;
    replacement.nextId = oldId;
    QVERIFY(replacementBus.registerObject("/org/freedesktop/Notifications", &replacement,
                                         QDBusConnection::ExportAllSlots | QDBusConnection::ExportAllSignals));
    QVERIFY(replacementBus.registerService("org.freedesktop.Notifications"));
    QTRY_VERIFY(notifications.supported());
    QVERIFY(notifications.show("new-thread", "Complete", "Done"));
    QTRY_COMPARE(replacement.issued.size(), 1);
    QCOMPARE(replacement.issued.last(), oldId);

    service.finishDelayedReply();
    QTRY_VERIFY(service.closed.contains(oldId));
    QCOMPARE(replacement.closed.size(), 0);
    QSignalSpy activated(&notifications, &NativeNotifications::activated);
    emit replacement.ActionInvoked(oldId, "default");
    QTRY_COMPARE(activated.size(), 1);
    QCOMPARE(activated.last().at(0).toString(), QString("new-thread"));
    notifications.setEnabled(false);
    QTRY_COMPARE(replacement.closed.size(), 1);
    QVERIFY(replacementBus.unregisterService("org.freedesktop.Notifications"));
    QDBusConnection::disconnectFromBus("replacement-daemon");
    QVERIFY(originalBus.registerService("org.freedesktop.Notifications"));
  }
};

QTEST_GUILESS_MAIN(NativeNotificationsTest)
#include "tst_NativeNotifications.moc"
