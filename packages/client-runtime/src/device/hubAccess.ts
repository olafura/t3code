/** Credentials for media requests that cannot set bearer or DPoP headers. */
export interface DeviceHubAccess {
  /** Absolute environment URL ending in `/api/device-hub`. */
  readonly httpBase: string;
  /** Same base with the `ws(s)` scheme. */
  readonly wsBase: string;
  /** Empty for cookie sessions; includes a short-lived ticket for bearer and DPoP sessions. */
  readonly query: Readonly<Record<string, string>>;
  /** Whether requests must include session cookies. */
  readonly credentials: boolean;
}

/**
 * Points access at the `hubBasePath` an environment reports. A cluster node names
 * itself there, so the node a client is connected to can relay to the node that
 * owns the device; servers that report the default path are unaffected.
 */
export const atDeviceHubBasePath = (
  access: DeviceHubAccess,
  hubBasePath: string | undefined,
): DeviceHubAccess => {
  if (!hubBasePath) return access;
  const url = new URL(access.httpBase);
  url.pathname = hubBasePath;
  const httpBase = url.toString();
  return { ...access, httpBase, wsBase: httpBase.replace(/^http/, "ws") };
};

export const withDeviceHubQuery = (url: string, access: DeviceHubAccess): string => {
  const entries = Object.entries(access.query);
  if (entries.length === 0) return url;
  const separator = url.includes("?") ? "&" : "?";
  return `${url}${separator}${new URLSearchParams(entries).toString()}`;
};
