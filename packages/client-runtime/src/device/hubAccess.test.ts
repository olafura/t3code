import { describe, expect, it } from "vite-plus/test";

import { atDeviceHubBasePath } from "./hubAccess.ts";

const access = {
  httpBase: "https://node.example.ts.net/api/device-hub",
  wsBase: "wss://node.example.ts.net/api/device-hub",
  query: { wsTicket: "ticket" },
  credentials: false,
};

describe("atDeviceHubBasePath", () => {
  it("routes through the connected origin to the node the state names", () => {
    expect(atDeviceHubBasePath(access, "/api/device-hub/nodes/t3%40mini")).toEqual({
      httpBase: "https://node.example.ts.net/api/device-hub/nodes/t3%40mini",
      wsBase: "wss://node.example.ts.net/api/device-hub/nodes/t3%40mini",
      query: { wsTicket: "ticket" },
      credentials: false,
    });
  });

  it("keeps access as it is before the state arrives", () => {
    expect(atDeviceHubBasePath(access, undefined)).toBe(access);
  });
});
