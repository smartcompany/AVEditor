/** Shared public URLs for store metadata (from deployment-kit/app-config.json). */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const configPath = path.join(__dirname, '..', 'app-config.json');
const raw = JSON.parse(fs.readFileSync(configPath, 'utf8'));

const serverBaseUrl = String(raw.serverBaseUrl ?? '')
  .trim()
  .replace(/\/$/, '');
const privacyPath = String(raw.privacyPath ?? '/privacy').trim();
const companySiteUrl = String(raw.supportUrl ?? 'https://smartcompany.github.io').trim();

const storeUrls = {
  baseUrl: serverBaseUrl,
  privacyUrl: `${serverBaseUrl}${privacyPath.startsWith('/') ? privacyPath : `/${privacyPath}`}`,
  supportUrl: companySiteUrl,
  marketingUrl: String(raw.marketingUrl ?? companySiteUrl).trim(),
  copyright: String(raw.copyright ?? '').trim(),
};

export default storeUrls;
export const { privacyUrl, supportUrl, marketingUrl, copyright } = storeUrls;
