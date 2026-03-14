import { Injectable, NestMiddleware } from '@nestjs/common';
import type { NextFunction, Request, Response } from 'express';
import { Counter, Histogram, register } from 'prom-client';

function getOrCreateCounter(): Counter<string> {
  const existing = register.getSingleMetric('retail_http_requests_total');
  if (existing) {
    return existing as Counter<string>;
  }

  return new Counter({
    name: 'retail_http_requests_total',
    help: 'Normalized HTTP request counter for Retail Store services.',
    labelNames: ['application', 'method', 'route', 'status'],
  });
}

function getOrCreateHistogram(): Histogram<string> {
  const existing = register.getSingleMetric('retail_http_request_duration_seconds');
  if (existing) {
    return existing as Histogram<string>;
  }

  return new Histogram({
    name: 'retail_http_request_duration_seconds',
    help: 'Normalized HTTP request duration histogram for Retail Store services.',
    labelNames: ['application', 'method', 'route', 'status'],
    buckets: [0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 2, 5],
  });
}

const requestCounter = getOrCreateCounter();
const requestDuration = getOrCreateHistogram();

@Injectable()
export class MetricsMiddleware implements NestMiddleware {
  use(request: Request, response: Response, next: NextFunction) {
    if (request.path === '/metrics') {
      next();
      return;
    }

    const start = process.hrtime.bigint();

    response.on('finish', () => {
      const durationSeconds = Number(process.hrtime.bigint() - start) / 1_000_000_000;
      const route =
        request.route?.path && request.baseUrl
          ? `${request.baseUrl}${request.route.path}`
          : request.originalUrl || request.path || 'unmatched';

      const labels = {
        application: 'checkout',
        method: request.method,
        route,
        status: String(response.statusCode),
      };

      requestCounter.inc(labels);
      requestDuration.observe(labels, durationSeconds);
    });

    next();
  }
}
