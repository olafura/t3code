// A stand-in for expo-device-hub's CLI (`--port N --host H ...`): the device list,
// boot and shutdown, and a screenshot, with Android emulators kept in memory.
// Booting "Broken" fails for lack of disk space. Every answer echoes the request
// URL in `x-fake-hub-url`, so tests can see what reached the hub, and the stream
// socket echoes what it gets.
import * as Crypto from "node:crypto";
import * as Http from "node:http";

const args = process.argv.slice(2);
const port = Number(args[args.indexOf("--port") + 1]);
const host = args[args.indexOf("--host") + 1];
const emulators = [];

// A PNG header is all a screenshot reader looks at: 390x844.
const png = Buffer.alloc(33);
Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13]).copy(png, 0);
png.write("IHDR", 12, "latin1");
png.writeUInt32BE(390, 16);
png.writeUInt32BE(844, 20);

const readBody = (request) =>
  new Promise((resolve) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => resolve(chunks.length ? JSON.parse(Buffer.concat(chunks)) : {}));
  });

const server = Http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://${host}`);
  response.setHeader("x-fake-hub-url", request.url);
  const json = (value) => {
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify(value));
  };

  if (url.pathname === "/readyz") return response.end("ok");
  if (url.pathname === "/api/devices") return json({ simulators: [], emulators, errors: [] });

  if (request.method === "POST" && url.pathname === "/api/devices/boot") {
    const body = await readBody(request);
    if (body.name === "Broken") return json({ ok: false, error: "Not enough disk space" });
    const serial = `emulator-${5554 + emulators.length * 2}`;
    emulators.push({
      id: serial,
      name: body.name,
      version: "Android 15.0",
      platform: "android",
      booted: true,
      physical: false,
    });
    return json({ ok: true, serial });
  }

  if (request.method === "POST" && url.pathname === "/api/devices/shutdown") {
    const body = await readBody(request);
    const index = emulators.findIndex((device) => device.id === body.id);
    if (index >= 0) emulators.splice(index, 1);
    return json({ ok: true });
  }

  if (url.pathname === "/vendor/serve-emu/api/screenshot") {
    response.setHeader("content-type", "image/png");
    return response.end(png);
  }

  response.statusCode = 404;
  response.end("not found");
});

// The emulator stream socket: greets with the URL it was opened at, then echoes
// JSON text frames. Frames stay under 126 bytes, so lengths fit in one byte.
server.on("upgrade", (request, socket) => {
  const accept = Crypto.createHash("sha1")
    .update(request.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    .digest("base64");
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  const frame = (value) => {
    const payload = Buffer.from(JSON.stringify(value));
    return Buffer.concat([Buffer.from([0x81, payload.length]), payload]);
  };
  socket.write(frame({ hello: request.url }));
  let buffer = Buffer.alloc(0);
  socket.on("data", (data) => {
    buffer = Buffer.concat([buffer, data]);
    while (buffer.length >= 6 && buffer.length >= 6 + (buffer[1] & 0x7f)) {
      const opcode = buffer[0] & 0x0f;
      const length = buffer[1] & 0x7f;
      const mask = buffer.subarray(2, 6);
      const payload = Buffer.from(buffer.subarray(6, 6 + length).map((b, i) => b ^ mask[i % 4]));
      buffer = buffer.subarray(6 + length);
      if (opcode === 0x8) return socket.end();
      if (opcode === 0x1) socket.write(frame({ echo: JSON.parse(payload.toString()) }));
    }
  });
});

server.listen(port, host);
