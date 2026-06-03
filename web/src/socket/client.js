import { Socket } from "phoenix";

const EVENTS = [
  "project:updated",
  "projects:updated",
  "site_settings:updated",
  "threads:updated",
  "thread:items",
  "turn:started",
  "item:created",
  "item:updated",
  "approval:requested",
  "approval:resolved",
  "agent:run_started",
  "assistant:delta",
  "tool:updated",
  "asset:created",
  "assets:updated",
  "board:items",
  "board:item:created",
  "board:item:updated",
  "asset:referenced",
  "agent:run_completed",
  "error",
];

export function createAvcsChannel(onEvent) {
  const socket = new Socket("/socket", {});
  socket.connect();

  const channel = socket.channel("avcs:lobby", {});
  EVENTS.forEach((event) => channel.on(event, (payload) => onEvent(event, payload)));

  const join = new Promise((resolve, reject) => {
    channel
      .join()
      .receive("ok", resolve)
      .receive("error", reject)
      .receive("timeout", () => reject(new Error("WebSocket join timed out")));
  });

  function push(event, payload = {}, timeoutMs) {
    return new Promise((resolve, reject) => {
      const pushRef =
        timeoutMs == null ? channel.push(event, payload) : channel.push(event, payload, timeoutMs);

      pushRef
        .receive("ok", (response) => {
          if (response?.success === false) {
            reject(new Error(response.error?.message || "Channel request failed"));
          } else {
            resolve(response?.data ?? response);
          }
        })
        .receive("error", reject)
        .receive("timeout", () => reject(new Error(`${event} timed out`)));
    });
  }

  return {
    join,
    push,
    disconnect() {
      channel.leave();
      socket.disconnect();
    },
  };
}
