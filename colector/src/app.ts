import type { NextFunction, Request, Response } from 'express';
import express from 'express';
import { pino } from "pino";

const app = express();
app.use(express.json({ limit: '1mb' }));

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  timestamp: pino.stdTimeFunctions.isoTime,
  formatters: { level: (label) => ({ level: label }) },
  base: { service: 'log-collector', env: process.env.NODE_ENV },
});

// ─────────────────────────────────────────
// FLUENT BIT FORWARD
// ─────────────────────────────────────────
const FLUENT_BIT_URL = process.env.FLUENT_BIT_URL || 'http://fluent-bit:8888';

let totalForwarded = 0;
let forwardErrors  = 0;

async function forwardToFluentBit(logs: any[]): Promise<void> {
  const payload = logs.map((log) => ({
    ...log,
    '@timestamp': log.timestamp || new Date().toISOString(),
    source: 'mobile',
    ingested_at: new Date().toISOString(),
  }));

  const response = await fetch(FLUENT_BIT_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    forwardErrors++;
    throw new Error(`Fluent Bit forward failed: ${response.status}`);
  }

  totalForwarded += logs.length;
}

// ─────────────────────────────────────────
// RATE LIMITER
// ─────────────────────────────────────────
const WINDOW_MS               = 1000;
const MAX_REQUESTS_PER_WINDOW = Number(process.env.RATE_LIMIT) || 100;

const rateLimitMap = new Map<string, { count: number; resetAt: number }>();

setInterval(() => {
  const now = Date.now();
  for (const [ip, entry] of rateLimitMap) {
    if (now > entry.resetAt) rateLimitMap.delete(ip);
  }
}, 30_000);

function rateLimiter(req: Request, res: Response, next: NextFunction): void {
  const ip = req.ip || req.socket.remoteAddress || 'unknown';
  const now = Date.now();
  const entry = rateLimitMap.get(ip);

  if (!entry || now > entry.resetAt) {
    rateLimitMap.set(ip, { count: 1, resetAt: now + WINDOW_MS });
    next();
    return;
  }

  entry.count++;
  if (entry.count > MAX_REQUESTS_PER_WINDOW) {
    logger.warn({ ip, count: entry.count }, 'rate limit exceeded');
    res.status(429).json({
      error: 'too_many_requests',
      retryAfter: Math.ceil((entry.resetAt - now) / 1000),
    });
    return;
  }

  next();
}

app.use('/logs', rateLimiter);

// ─────────────────────────────────────────
// ROUTES
// ─────────────────────────────────────────

app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    uptime: process.uptime(),
    totalForwarded,
    forwardErrors,
  });
});

app.get('/metrics', (_req, res) => {
  res.json({
    totalForwarded,
    forwardErrors,
    rateLimitPerSec: MAX_REQUESTS_PER_WINDOW,
    uptime: process.uptime(),
  });
});

app.post('/logs/mobile', async (req: Request, res: Response) => {
  let logs: any[];

  if (req.body.logs && Array.isArray(req.body.logs)) {
    logs = req.body.logs;
  } else if (Array.isArray(req.body)) {
    logs = req.body;
  } else if (typeof req.body === 'object' && req.body !== null) {
    logs = [req.body];
  } else {
    res.status(400).json({ error: 'invalid body format' });
    return;
  }

  if (logs.length === 0) {
    res.status(400).json({ error: 'logs must be a non-empty array' });
    return;
  }
  if (logs.length > 500) {
    res.status(400).json({ error: 'max 500 logs per batch' });
    return;
  }

  try {
    await forwardToFluentBit(logs);
    logger.info({ count: logs.length }, 'forwarded to fluent-bit');
    res.json({ ok: true, forwarded: logs.length });
  } catch (err) {
    logger.error({ err, count: logs.length }, 'forward to fluent-bit failed');
    res.status(502).json({ error: 'failed to forward logs' });
  }
});

// ─────────────────────────────────────────
// GLOBAL ERROR HANDLER
// ─────────────────────────────────────────
app.use((err: Error, _req: Request, res: Response, _next: NextFunction) => {
  logger.error({ err }, 'unhandled error');
  res.status(500).json({ error: 'internal server error' });
});

// ─────────────────────────────────────────
// START
// ─────────────────────────────────────────
const PORT = Number(process.env.PORT) || 4000;
app.listen(PORT, () => logger.info({ port: PORT }, 'log collector started'));

process.on('SIGTERM', () => { logger.info('SIGTERM received'); process.exit(0); });
process.on('SIGINT',  () => { logger.info('SIGINT received');  process.exit(0); });
process.on('uncaughtException',  (err) => { logger.fatal({ err }, 'uncaught exception'); process.exit(1); });
process.on('unhandledRejection', (reason) => logger.error({ reason }, 'unhandled rejection'));