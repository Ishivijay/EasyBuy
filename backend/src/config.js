import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const envPath = path.join(here, '..', '.env');

if (existsSync(envPath)) {
  // Node >= 20.12 ships this natively, so we avoid a dotenv dependency.
  process.loadEnvFile(envPath);
}

export const config = {
  apiKey: process.env.YOUCAM_API_KEY || '',
  apiSecret: process.env.YOUCAM_API_SECRET || '',
  baseUrl: (process.env.YOUCAM_BASE_URL || 'https://yce-api-01.makeupar.com').replace(/\/$/, ''),
  port: Number(process.env.PORT || 8787),
};

export function assertConfigured() {
  if (!config.apiKey) {
    throw new Error(
      'YOUCAM_API_KEY is not set. Copy .env.example to backend/.env and paste your key from ' +
        'https://yce.makeupar.com/api-console/en/api-keys/'
    );
  }
}
