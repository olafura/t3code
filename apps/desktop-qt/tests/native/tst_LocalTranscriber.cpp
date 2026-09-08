#include <QCoreApplication>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QSignalSpy>
#include <QTest>
#include <QTemporaryDir>
#include <iostream>
#include <memory>
#ifdef Q_OS_LINUX
#include <signal.h>
#include <unistd.h>
#endif

#include "LocalTranscriber.h"

class LocalTranscriberTest : public QObject {
  Q_OBJECT
private:
  void configure(LocalTranscriber& transcriber, const QString& mode = QStringLiteral("success")) {
    transcriber.setProperty("program", QCoreApplication::applicationFilePath());
    transcriber.setProperty("arguments", QStringList{QStringLiteral("--fixture"), mode});
  }

private slots:
  void qmlTypeAcceptsExplicitConfiguration() {
    qmlRegisterType<LocalTranscriber>("T3.DictationTest", 1, 0, "LocalTranscriber");
    QQmlEngine engine;
    QQmlComponent component(&engine);
    component.setData("import T3.DictationTest 1.0\nLocalTranscriber { program: \"/configured/python\"; arguments: [\"/path with spaces/helper.py\", \"--language\", \"zh-CN\"] }", QUrl());
    QVERIFY2(component.isReady(), qPrintable(component.errorString()));
    std::unique_ptr<QObject> object(component.create());
    QVERIFY(object);
    QCOMPARE(object->property("program").toString(), QStringLiteral("/configured/python"));
    QCOMPARE(object->property("arguments").toStringList(), QStringList({QStringLiteral("/path with spaces/helper.py"), QStringLiteral("--language"), QStringLiteral("zh-CN")}));
    QCOMPARE(object->property("running").toBool(), false);
  }

  void argumentVectorIsNotEvaluatedByAShell() {
    LocalTranscriber transcriber;
    configure(transcriber);
    const QString value = QString::fromUtf8("把 verifyToken 改掉; $(must-not-run) ' quoted");
    transcriber.setProperty("arguments", QStringList{QStringLiteral("--fixture"), QStringLiteral("echo"), value});
    QSignalSpy ready(&transcriber, &LocalTranscriber::transcriptReady);
    QVERIFY(transcriber.start());
    QTRY_COMPARE(ready.count(), 1);
    QCOMPARE(ready.first().first().toString(), value);
  }

#ifdef Q_OS_LINUX
  void cancellationStopsARecorderThatIgnoresTermination_data() {
    QTest::addColumn<bool>("destroy");
    QTest::newRow("cancel") << false;
    QTest::newRow("destroy") << true;
  }

  void cancellationStopsARecorderThatIgnoresTermination() {
    QFETCH(bool, destroy);
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto pidFile = directory.filePath("recorder.pid");
    auto transcriber = std::make_unique<LocalTranscriber>();
    configure(*transcriber);
    transcriber->setProperty("arguments", QStringList{QStringLiteral("--fixture"), QStringLiteral("recorder"), pidFile});
    QVERIFY(transcriber->start());
    QTRY_COMPARE(transcriber->status(), QStringLiteral("recording"));
    QFile recorderPid(pidFile);
    QVERIFY(recorderPid.open(QIODevice::ReadOnly));
    const auto pid = recorderPid.readAll().toLongLong();
    QVERIFY(pid > 0);
    const auto recorderStopped = [pid] {
      QFile state(QStringLiteral("/proc/%1/stat").arg(pid));
      return !state.open(QIODevice::ReadOnly) || state.readAll().contains(") Z ");
    };
    QVERIFY(!recorderStopped());
    if (destroy) transcriber.reset();
    else {
      transcriber->cancel();
      QTRY_VERIFY(!transcriber->running());
    }
    QTRY_VERIFY(recorderStopped());
  }
#endif

  void unconfiguredDoesNotStart() {
    LocalTranscriber transcriber;
    QVERIFY(!transcriber.start());
    QVERIFY(!transcriber.running());
    QVERIFY(!transcriber.error().isEmpty());
  }

  void stopRecordingReturnsUnicodeTranscript() {
    LocalTranscriber transcriber;
    configure(transcriber);
    QSignalSpy ready(&transcriber, &LocalTranscriber::transcriptReady);
    QVERIFY(transcriber.start());
    QVERIFY(!transcriber.start());
    QTRY_COMPARE(transcriber.status(), QStringLiteral("recording"));
    transcriber.finishRecording();
    QTRY_COMPARE(ready.count(), 1);
    QCOMPARE(ready.first().first().toString(), QString::fromUtf8("把 src/auth.ts 里的 verifyToken 改掉"));
    QVERIFY(!transcriber.running());
    QVERIFY(transcriber.error().isEmpty());
  }

  void cancelDiscardsOutputAndAllowsRestart() {
    LocalTranscriber transcriber;
    configure(transcriber);
    QSignalSpy ready(&transcriber, &LocalTranscriber::transcriptReady);
    QVERIFY(transcriber.start());
    QTRY_COMPARE(transcriber.status(), QStringLiteral("recording"));
    transcriber.cancel();
    QTRY_VERIFY(!transcriber.running());
    QCOMPARE(ready.count(), 0);
    QVERIFY(transcriber.error().isEmpty());
    QVERIFY(transcriber.start());
    QTRY_COMPARE(transcriber.status(), QStringLiteral("recording"));
    transcriber.finishRecording();
    QTRY_COMPARE(ready.count(), 1);
  }

  void helperFailureDoesNotDeliverItsTranscript() {
    LocalTranscriber transcriber;
    configure(transcriber, QStringLiteral("failure"));
    QSignalSpy ready(&transcriber, &LocalTranscriber::transcriptReady);
    QVERIFY(transcriber.start());
    QTRY_VERIFY(!transcriber.running());
    QCOMPARE(ready.count(), 0);
    QVERIFY(transcriber.error().contains(QStringLiteral("Fixture failure")));
  }

  void excessiveOutputIsRejected() {
    LocalTranscriber transcriber;
    configure(transcriber, QStringLiteral("oversized"));
    QSignalSpy ready(&transcriber, &LocalTranscriber::transcriptReady);
    QVERIFY(transcriber.start());
    QTRY_VERIFY(!transcriber.running());
    QCOMPARE(ready.count(), 0);
    QVERIFY(transcriber.error().contains(QStringLiteral("output limit")));
  }
};

int main(int argc, char** argv) {
  QCoreApplication app(argc, argv);
  const auto args = app.arguments();
  if (args.contains(QStringLiteral("--fixture"))) {
    const auto mode = args.value(args.indexOf(QStringLiteral("--fixture")) + 1);
    if (mode == QStringLiteral("echo")) {
      const QJsonObject result{{"type", "transcript"}, {"text", args.last()}};
      std::cout << QJsonDocument(result).toJson(QJsonDocument::Compact).constData() << '\n' << std::flush;
      return 0;
    }
#ifdef Q_OS_LINUX
    if (mode == QStringLiteral("recorder")) {
      const auto child = ::fork();
      if (child < 0) return 4;
      if (child == 0) {
        ::signal(SIGTERM, SIG_IGN);
        for (;;) ::pause();
      }
      QFile pidFile(args.last());
      if (!pidFile.open(QIODevice::WriteOnly)) return 5;
      pidFile.write(QByteArray::number(child));
      pidFile.close();
    }
#endif
    if (mode == QStringLiteral("oversized")) {
      std::cout << std::string(1024 * 1024 + 1, 'x') << std::flush;
      return 0;
    }
    if (mode == QStringLiteral("failure")) {
      std::cout << "{\"type\":\"transcript\",\"text\":\"must not deliver\"}\n" << std::flush;
      std::cerr << "Fixture failure" << std::flush;
      return 2;
    }
    std::cout << "{\"type\":\"status\",\"phase\":\"recording\"}\n" << std::flush;
    std::string command;
    std::getline(std::cin, command);
    if (command != "stop") return 3;
    const QJsonObject result{{"type", "transcript"}, {"text", QString::fromUtf8("把 src/auth.ts 里的 verifyToken 改掉")}};
    std::cout << QJsonDocument(result).toJson(QJsonDocument::Compact).constData() << '\n' << std::flush;
    return 0;
  }
  LocalTranscriberTest test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_LocalTranscriber.moc"
