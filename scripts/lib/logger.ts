type LogLevel = "error" | "success" | "info" | "debug";

const DEBUG_ENABLED = process.env.DEBUG_LOGS === "true";

function emit(level: LogLevel, message: string, context?: Record<string, unknown>): void {
  if (level === "debug" && !DEBUG_ENABLED) {
    return;
  }
  const entry: Record<string, unknown> = {
    level,
    message,
    time: new Date().toISOString(),
    ...context,
  };
  console.log(JSON.stringify(entry));
}

export const logger = {
  error(message: string, context?: Record<string, unknown>): void {
    emit("error", message, context);
  },
  success(message: string, context?: Record<string, unknown>): void {
    emit("success", message, context);
  },
  info(message: string, context?: Record<string, unknown>): void {
    emit("info", message, context);
  },
  debug(message: string, context?: Record<string, unknown>): void {
    emit("debug", message, context);
  },
};