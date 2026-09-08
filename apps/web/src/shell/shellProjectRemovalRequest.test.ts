import { describe, expect, it, vi } from "vite-plus/test";
import {
  requestShellProjectRemoval,
  subscribeShellProjectRemovalRequests,
} from "./shellProjectRemovalRequest";

describe("shell project removal handoff", () => {
  it("confirms only the requested physical checkout in a mounted grouped project", () => {
    const local = vi.fn();
    const remote = vi.fn();
    const unsubscribe = subscribeShellProjectRemovalRequests([
      { projectKey: "local:one", confirm: local },
      { projectKey: "remote:one", confirm: remote },
    ]);
    requestShellProjectRemoval("local:one");
    expect(local).toHaveBeenCalledOnce();
    expect(remote).not.toHaveBeenCalled();
    unsubscribe();
  });

  it("hands navigation to the next matching view only once", () => {
    requestShellProjectRemoval("local:two");
    const confirm = vi.fn();
    subscribeShellProjectRemovalRequests([{ projectKey: "local:two", confirm }])();
    subscribeShellProjectRemovalRequests([{ projectKey: "local:two", confirm }])();
    expect(confirm).toHaveBeenCalledOnce();
  });

  it("drops a request when another project view mounts", () => {
    requestShellProjectRemoval("local:three");
    const confirm = vi.fn();
    subscribeShellProjectRemovalRequests([{ projectKey: "local:other", confirm }])();
    subscribeShellProjectRemovalRequests([{ projectKey: "local:three", confirm }])();
    expect(confirm).not.toHaveBeenCalled();
  });

  it("cancels failed navigation without clearing a newer request", () => {
    const cancelOld = requestShellProjectRemoval("local:old");
    requestShellProjectRemoval("local:new");
    cancelOld();
    const confirm = vi.fn();
    subscribeShellProjectRemovalRequests([{ projectKey: "local:new", confirm }])();
    expect(confirm).toHaveBeenCalledOnce();
    const cancel = requestShellProjectRemoval("local:canceled");
    cancel();
    subscribeShellProjectRemovalRequests([{ projectKey: "local:canceled", confirm }])();
    expect(confirm).toHaveBeenCalledOnce();
  });

  it("does not deliver to an unmounted view", () => {
    const confirm = vi.fn();
    subscribeShellProjectRemovalRequests([{ projectKey: "local:gone", confirm }])();
    const cancel = requestShellProjectRemoval("local:gone");
    expect(confirm).not.toHaveBeenCalled();
    cancel();
  });
});
