#!/usr/bin/env node
/**
 * Set App Store Connect subscription groupLevel via API
 * (avoids the flaky Edit Order drag UI).
 *
 * Target layout (1 = highest service):
 *   Studio monthly/annual → 1
 *   Pro monthly/annual    → 2
 *   Plus monthly/annual   → 3
 *
 * Usage:
 *   ./set-subscription-levels.sh
 *   ./set-subscription-levels.sh --dry-run
 */

import { ascFetch, requireAscEnv, resolveAppId } from './lib/asc.mjs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** productId → groupLevel (1 = highest) */
const LEVEL_BY_PRODUCT_ID = {
  'com.smartcompany.aveditor.studio.monthly': 1,
  'com.smartcompany.aveditor.studio.annual': 1,
  'com.smartcompany.aveditor.pro.monthly': 2,
  'com.smartcompany.aveditor.pro.annual': 2,
  'com.smartcompany.aveditor.plus.monthly': 3,
  'com.smartcompany.aveditor.plus.annual': 3,
};

function parseArgs(argv) {
  return { dryRun: argv.includes('--dry-run') };
}

async function listAll(token, firstPath) {
  const rows = [];
  let next = firstPath;
  while (next) {
    const json = await ascFetch(
      token,
      next.startsWith('http') ? next.replace(API_PREFIX, '') : next,
    );
    rows.push(...(json.data ?? []));
    const nextUrl = json.links?.next;
    if (!nextUrl) break;
    next = nextUrl.replace('https://api.appstoreconnect.apple.com/v1', '');
  }
  return rows;
}

const API_PREFIX = 'https://api.appstoreconnect.apple.com/v1';

async function main() {
  const { dryRun } = parseArgs(process.argv.slice(2));
  const env = requireAscEnv(__dirname);
  const appId = await resolveAppId(env.token, env);
  console.log(`App: ${appId} (${env.bundleId})`);
  if (dryRun) console.log('Mode: dry-run (no PATCH)\n');

  const groups = await listAll(
    env.token,
    `/apps/${appId}/subscriptionGroups?limit=50`,
  );
  if (groups.length === 0) {
    throw new Error('No subscription groups found for this app');
  }

  let updated = 0;
  let skipped = 0;
  let missing = new Set(Object.keys(LEVEL_BY_PRODUCT_ID));

  for (const group of groups) {
    const groupName = group.attributes?.referenceName ?? group.id;
    console.log(`\nGroup: ${groupName} (${group.id})`);

    const subs = await listAll(
      env.token,
      `/subscriptionGroups/${group.id}/subscriptions?limit=50`,
    );
    for (const sub of subs) {
      const productId = sub.attributes?.productId ?? '';
      const name = sub.attributes?.name ?? '';
      const current = sub.attributes?.groupLevel;
      const wanted = LEVEL_BY_PRODUCT_ID[productId];
      if (wanted == null) {
        console.log(
          `  skip  ${productId || name}  (no mapping)  currentLevel=${current}`,
        );
        continue;
      }
      missing.delete(productId);
      if (current === wanted) {
        console.log(`  ok    ${productId}  level=${current}`);
        skipped += 1;
        continue;
      }
      console.log(
        `  set   ${productId}  level ${current ?? '?'} → ${wanted}`,
      );
      if (dryRun) {
        updated += 1;
        continue;
      }
      await ascFetch(env.token, `/subscriptions/${sub.id}`, {
        method: 'PATCH',
        body: {
          data: {
            type: 'subscriptions',
            id: sub.id,
            attributes: { groupLevel: wanted },
          },
        },
      });
      updated += 1;
    }
  }

  if (missing.size > 0) {
    console.log('\nNot found in ASC (check Product ID):');
    for (const id of [...missing].sort()) console.log(`  - ${id}`);
  }

  console.log(
    `\nDone. updated=${updated} alreadyOk=${skipped} dryRun=${dryRun}`,
  );
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
