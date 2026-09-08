#pragma once

#include <QObject>
#include <QProcess>
#include <QStringList>
#include <QTimer>

// Trusted local QML may opt into one explicitly configured transcription
// helper. This type is not exposed to the hosted page through WebChannel.
class LocalTranscriber : public QObject {
  Q_OBJECT
  Q_PROPERTY(QString program MEMBER m_program NOTIFY configurationChanged)
  Q_PROPERTY(QStringList arguments MEMBER m_arguments NOTIFY configurationChanged)
  Q_PROPERTY(bool running READ running NOTIFY stateChanged)
  Q_PROPERTY(QString status READ status NOTIFY stateChanged)
  Q_PROPERTY(QString error READ error NOTIFY errorChanged)

public:
  explicit LocalTranscriber(QObject* parent = nullptr);
  ~LocalTranscriber() override;
  bool running() const { return m_process.state() != QProcess::NotRunning; }
  QString status() const { return m_status; }
  QString error() const { return m_error; }
  Q_INVOKABLE bool start();
  Q_INVOKABLE void finishRecording();
  Q_INVOKABLE void cancel();

signals:
  void configurationChanged();
  void stateChanged();
  void errorChanged();
  void transcriptReady(const QString& text);

private:
  void setStatus(const QString& status);
  void fail(const QString& error);
  void readOutput();
  void parseLine(const QByteArray& line);
  void stopProcess(bool force);

  QString m_program;
  QStringList m_arguments;
  QProcess m_process;
  QTimer m_killTimer;
  QString m_status = QStringLiteral("idle");
  QString m_error;
  QByteArray m_output;
  QByteArray m_stderr;
  QString m_transcript;
  qint64 m_outputBytes = 0;
  qint64 m_ownedProcessGroup = 0;
  bool m_receivedTranscript = false;
  bool m_cancelled = false;
};
