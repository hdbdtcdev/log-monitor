import express from 'express';
import type { Request, Response, NextFunction } from 'express';
import { pino } from "pino";

const app = express();
app.use(express.json({ limit: '1mb' })); // batch log có thể lớn

// ─────────────────────────────────────────
// LOGGER — collector tự log hoạt động của nó
// ─────────────────────────────────────────
const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  timestamp: pino.stdTimeFunctions.isoTime,
  formatters: { level: (label) => ({ level: label }) },
  base: { service: 'log-collector', env: process.env.NODE_ENV },
});

// ─────────────────────────────────────────
// OPENSEARCH CLIENT
// ─────────────────────────────────────────
const OPENSEARCH_URL  = process.env.OPENSEARCH_URL  || 'http://opensearch-headless:9200';
const OPENSEARCH_USER = process.env.OPENSEARCH_USER || 'admin';
const OPENSEARCH_PASS = process.env.OPENSEARCH_PASS || 'admin';
const INDEX_PREFIX    = 'mobile-logs';

async function bulkIndexToOpenSearch(logs: any[]) {
  // Tạo bulk body — OpenSearch bulk API cần xen kẽ action + document
  const bulkBody = logs.flatMap((log) => [
    {
      index: {
        _index: `${INDEX_PREFIX}-${new Date().toISOString().slice(0, 10)}`,
      },
    },
    {
      ...log,
      '@timestamp': log.timestamp || new Date().toISOString(),
      // Đảm bảo luôn có source field để phân biệt với server logs
      source: 'mobile',
    },
  ]);

  const body = bulkBody.map((line) => JSON.stringify(line)).join('\n') + '\n';

  const response = await fetch(`${OPENSEARCH_URL}/_bulk`, {
    method:  'POST',
    headers: {
      'Content-Type': 'application/x-ndjson',
      Authorization: `Basic ${Buffer.from(`${OPENSEARCH_USER}:${OPENSEARCH_PASS}`).toString('base64')}`,
    },
    body,
  });

  if (!response.ok) {
    throw new Error(`OpenSearch bulk failed: ${response.status}`);
  }

  return await response.json();
}

// ─────────────────────────────────────────
// ROUTES
// ─────────────────────────────────────────

app.get('/health', (_req, res) => {
  res.json({ status: 'ok' });
});

// Endpoint nhận log batch từ mobile SDK
app.post('/logs/mobile', async (req: Request, res: Response) => {
  const { logs } = req.body;

  // Validate
  if (!Array.isArray(logs) || logs.length === 0) {
    return res.status(400).json({ error: 'logs must be a non-empty array' });
  }
  if (logs.length > 500) {
    return res.status(400).json({ error: 'max 500 logs per batch' });
  }

  logger.info({ count: logs.length }, 'received mobile log batch');

  try {
    await bulkIndexToOpenSearch(logs);

    logger.info({ count: logs.length }, 'indexed to opensearch');
    res.json({ ok: true, indexed: logs.length });

  } catch (err) {
    logger.error({ err }, 'failed to index logs');
    res.status(500).json({ error: 'failed to store logs' });
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
const PORT = Number(process.env.PORT) || 4008;
app.listen(PORT, () => logger.info({ port: PORT }, 'log collector started'));

process.on('uncaughtException',  (err) => { logger.fatal({ err }, 'uncaught exception'); process.exit(1); });
process.on('unhandledRejection', (reason) => logger.error({ reason }, 'unhandled rejection'));