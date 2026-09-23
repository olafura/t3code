// A stand-in for the agent-device CLI: any command "starts" the daemon by writing
// daemon.json to AGENT_DEVICE_STATE_DIR, as the real CLI does; `daemon stop` exits.
import * as Fs from "node:fs";
import * as Path from "node:path";

const args = process.argv.slice(2);
if (args[0] !== "daemon") {
  const dir = process.env.AGENT_DEVICE_STATE_DIR;
  Fs.mkdirSync(dir, { recursive: true });
  Fs.writeFileSync(
    Path.join(dir, "daemon.json"),
    JSON.stringify({ httpPort: 1, token: "fake-token", version: "0.21.12" }),
  );
  console.log("[]");
}
