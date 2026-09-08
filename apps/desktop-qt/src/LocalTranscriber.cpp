#include "LocalTranscriber.h"

#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#ifdef Q_OS_UNIX
#include <signal.h>
#endif

LocalTranscriber::LocalTranscriber(QObject* parent) : QObject(parent) {
#ifdef Q_OS_UNIX
  // Own a separate group so cancelling the helper also stops its recorder,
  // including a recorder left behind if the helper itself exits first.
  m_process.setUnixProcessParameters(QProcess::UnixProcessFlag::CreateNewSession);
#endif
  m_killTimer.setSingleShot(true);
  m_killTimer.setInterval(1000);
  connect(&m_killTimer, &QTimer::timeout, this, [this] { stopProcess(true); });
  connect(&m_process, &QProcess::started, this, [this] {
    m_ownedProcessGroup = m_process.processId();
    if (m_cancelled || !m_error.isEmpty()) stopProcess(false);
  });
  connect(&m_process, &QProcess::stateChanged, this, &LocalTranscriber::stateChanged);
  connect(&m_process, &QProcess::readyReadStandardOutput, this, &LocalTranscriber::readOutput);
  connect(&m_process, &QProcess::readyReadStandardError, this, [this] {
    m_stderr = (m_stderr + m_process.readAllStandardError()).right(8192);
  });
  connect(&m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
    if (error == QProcess::FailedToStart) {
      fail(m_process.errorString());
      setStatus(QStringLiteral("idle"));
    }
  });
  connect(&m_process, &QProcess::finished, this, [this](int code, QProcess::ExitStatus exitStatus) {
    m_killTimer.stop();
    stopProcess(true);
    m_ownedProcessGroup = 0;
    readOutput();
    if (!m_output.isEmpty() && m_error.isEmpty() && !m_cancelled) parseLine(m_output);
    m_output.clear();
    if (!m_cancelled && m_error.isEmpty()) {
      if (exitStatus != QProcess::NormalExit || code != 0) {
        const auto detail = QString::fromUtf8(m_stderr).trimmed();
        fail(detail.isEmpty() ? tr("The transcription helper failed.") : detail);
      } else if (!m_receivedTranscript || m_transcript.trimmed().isEmpty()) {
        fail(tr("The transcription helper returned no speech."));
      }
    }
    const auto transcript = m_transcript;
    const bool deliver = !m_cancelled && m_error.isEmpty();
    setStatus(QStringLiteral("idle"));
    if (deliver) emit transcriptReady(transcript);
  });
}

LocalTranscriber::~LocalTranscriber() {
  m_killTimer.stop();
  m_process.disconnect(this);
  if (running()) {
    stopProcess(false);
    if (!m_process.waitForFinished(1000)) {
      stopProcess(true);
      m_process.waitForFinished(1000);
    }
  }
  stopProcess(true);
}

bool LocalTranscriber::start() {
  if (running()) return false;
  m_output.clear();
  m_stderr.clear();
  m_transcript.clear();
  m_outputBytes = 0;
  m_receivedTranscript = false;
  m_cancelled = false;
  m_error.clear();
  emit errorChanged();
  const QFileInfo executable(m_program);
  if (!executable.isAbsolute() || !executable.isFile() || !executable.isExecutable()) {
    fail(tr("Choose an existing absolute transcription executable path."));
    return false;
  }
  setStatus(QStringLiteral("starting"));
  m_process.start(m_program, m_arguments);
  return true;
}

void LocalTranscriber::finishRecording() {
  if (running() && m_status == QStringLiteral("recording")) {
    m_process.write("stop\n");
    setStatus(QStringLiteral("transcribing"));
  }
}

void LocalTranscriber::cancel() {
  if (!running() || m_cancelled) return;
  m_cancelled = true;
  setStatus(QStringLiteral("cancelling"));
  stopProcess(false);
  m_killTimer.start();
}

void LocalTranscriber::setStatus(const QString& status) {
  if (m_status == status) return;
  m_status = status;
  emit stateChanged();
}

void LocalTranscriber::fail(const QString& error) {
  if (!m_error.isEmpty()) return;
  m_error = error;
  emit errorChanged();
  if (running()) {
    stopProcess(false);
    m_killTimer.start();
  }
}

void LocalTranscriber::stopProcess(bool force) {
#ifdef Q_OS_UNIX
  if (m_ownedProcessGroup > 0) {
    ::kill(-static_cast<pid_t>(m_ownedProcessGroup), force ? SIGKILL : SIGTERM);
    return;
  }
#endif
  if (force) m_process.kill();
  else m_process.terminate();
}

void LocalTranscriber::readOutput() {
  const auto bytes = m_process.readAllStandardOutput();
  m_outputBytes += bytes.size();
  if (m_cancelled || !m_error.isEmpty()) return;
  if (m_outputBytes > 1024 * 1024) {
    fail(tr("The transcription helper exceeded the output limit."));
    return;
  }
  m_output += bytes;
  qsizetype newline;
  while ((newline = m_output.indexOf('\n')) >= 0) {
    const auto line = m_output.first(newline);
    m_output.remove(0, newline + 1);
    parseLine(line);
    if (!m_error.isEmpty()) return;
  }
}

void LocalTranscriber::parseLine(const QByteArray& line) {
  if (line.trimmed().isEmpty()) return;
  QJsonParseError error;
  const auto document = QJsonDocument::fromJson(line, &error);
  const auto message = document.object();
  const auto type = message.value(QStringLiteral("type")).toString();
  if (error.error != QJsonParseError::NoError || !document.isObject()) {
    fail(tr("The transcription helper returned invalid JSON."));
  } else if (type == QStringLiteral("status")) {
    const auto phase = message.value(QStringLiteral("phase")).toString();
    if (phase == QStringLiteral("recording") || phase == QStringLiteral("transcribing")) setStatus(phase);
    else fail(tr("The transcription helper returned an unknown phase."));
  } else if (type == QStringLiteral("transcript") && !m_receivedTranscript && message.value(QStringLiteral("text")).isString()) {
    m_receivedTranscript = true;
    m_transcript = message.value(QStringLiteral("text")).toString();
  } else {
    fail(tr("The transcription helper returned an unexpected message."));
  }
}
