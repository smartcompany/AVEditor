#!/usr/bin/env node
/**
 * Fill App Store Connect subscription detail pages via API:
 *   - Availability (all territories + new territories)
 *   - Prices (USA base + equalized everywhere, planType UPFRONT)
 *   - Localizations (en-US / ko / ja / zh-Hans)
 *   - Promotional image (1024×1024)
 *   - App Review screenshot (phone-sized JPG under docs/store-assets/review/)
 *   - Retention message (shared copy, assigned to every product)
 *   - Subscription group display name + custom app name (4 locales)
 *
 * Usage:
 *   ./set-subscription-details.sh
 *   ./set-subscription-details.sh --dry-run
 *   ./set-subscription-details.sh --only localizations,prices
 *   ./set-subscription-details.sh --only retention
 *   ./set-subscription-details.sh --only groupLocalizations
 *   ./set-subscription-details.sh --product com.smartcompany.aveditor.studio.annual
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  ascFetch,
  ascListAll,
  requireAscEnv,
  resolveAppId,
  sleep,
  uploadAscAsset,
} from './lib/asc.mjs';
import {
  BASE_TERRITORY,
  PLAN_TYPE,
  RETENTION_MESSAGE,
  SUBSCRIPTION_GROUP_LOCALIZATIONS,
  SUBSCRIPTIONS,
} from './subscriptions.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const ALL_STEPS = [
  'availability',
  'prices',
  'localizations',
  'promo',
  'review',
  'retention',
  'groupLocalizations',
];

/** Only PREPARE_FOR_SUBMISSION accepts localization edits. */
const MUTABLE_RETENTION_STATES = new Set(['PREPARE_FOR_SUBMISSION']);

function parseArgs(argv) {
  const out = {
    dryRun: false,
    only: new Set(ALL_STEPS),
    products: null,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--dry-run') out.dryRun = true;
    else if (a === '--only') {
      const raw = String(argv[++i] ?? '');
      out.only = new Set(
        raw
          .split(',')
          .map((s) => s.trim())
          .filter(Boolean),
      );
    } else if (a === '--product') {
      const id = String(argv[++i] ?? '').trim();
      if (!out.products) out.products = new Set();
      out.products.add(id);
    } else if (a === '--help' || a === '-h') {
      out.help = true;
    }
  }
  return out;
}

function md5File(buf) {
  return crypto.createHash('md5').update(buf).digest('hex');
}

async function loadTerritories(token) {
  const rows = await ascListAll(token, `/territories?limit=200`);
  return rows.map((t) => ({ type: 'territories', id: t.id }));
}

async function indexSubscriptions(token, appId) {
  const groups = await ascListAll(
    token,
    `/apps/${appId}/subscriptionGroups?limit=50`,
  );
  const byProduct = new Map();
  for (const group of groups) {
    const subs = await ascListAll(
      token,
      `/subscriptionGroups/${group.id}/subscriptions?limit=50`,
    );
    for (const sub of subs) {
      byProduct.set(sub.attributes?.productId, sub);
    }
  }
  return byProduct;
}

async function ensureAvailability(token, sub, territories, dryRun) {
  const existing = await ascFetch(
    token,
    `/subscriptions/${sub.id}/subscriptionAvailability`,
  ).catch(() => null);

  let terrCount = 0;
  if (existing?.data?.id) {
    const terrs = await ascListAll(
      token,
      `/subscriptionAvailabilities/${existing.data.id}/availableTerritories?limit=200`,
    );
    terrCount = terrs.length;
  }

  const wantsAll = territories.length;
  if (existing?.data?.id && terrCount >= wantsAll) {
    return `ok territories=${terrCount}`;
  }

  if (dryRun) {
    return `would set territories=${wantsAll} (have ${terrCount})`;
  }

  await ascFetch(token, `/subscriptionAvailabilities`, {
    method: 'POST',
    body: {
      data: {
        type: 'subscriptionAvailabilities',
        attributes: { availableInNewTerritories: true },
        relationships: {
          subscription: {
            data: { type: 'subscriptions', id: sub.id },
          },
          availableTerritories: { data: territories },
        },
      },
    },
  });
  return `set territories=${wantsAll}`;
}

async function findUsaPricePoint(token, subId, usaPrice) {
  const points = await ascListAll(
    token,
    `/subscriptions/${subId}/pricePoints?filter[territory]=${BASE_TERRITORY}&limit=200`,
  );
  const match = points.find(
    (p) => String(p.attributes?.customerPrice) === String(usaPrice),
  );
  if (!match) {
    throw new Error(
      `No USA price point for $${usaPrice} on subscription ${subId}`,
    );
  }
  return match;
}

async function listPricesByTerritory(token, subId) {
  const byTerritory = new Map();
  let next = `/subscriptions/${subId}/prices?include=subscriptionPricePoint,territory&limit=200`;
  while (next) {
    const path = next.startsWith('http')
      ? next.replace('https://api.appstoreconnect.apple.com/v1', '')
      : next;
    const page = await ascFetch(token, path);
    const included = page.included ?? [];
    for (const row of page.data ?? []) {
      const tid = row.relationships?.territory?.data?.id;
      if (!tid) continue;
      const pp = included.find(
        (i) =>
          i.type === 'subscriptionPricePoints' &&
          i.id === row.relationships?.subscriptionPricePoint?.data?.id,
      );
      byTerritory.set(tid, {
        priceId: row.id,
        customerPrice: pp?.attributes?.customerPrice,
        planType: row.attributes?.planType,
      });
    }
    next = page.links?.next || null;
  }
  return byTerritory;
}

/**
 * Set equalized prices for every territory in ONE request via
 * PATCH /v1/subscriptions/{id} + included local ids (${priceN}).
 * (POST /v1/subscriptionPrices is one territory per call — 175× slower.)
 */
async function ensurePrices(token, sub, usaPrice, dryRun) {
  const currentByTerritory = await listPricesByTerritory(token, sub.id);
  const usaPoint = await findUsaPricePoint(token, sub.id, usaPrice);
  const equalized = await ascListAll(
    token,
    `/subscriptionPricePoints/${usaPoint.id}/equalizations?include=territory&limit=200`,
  );

  const targets = [
    {
      territory: BASE_TERRITORY,
      pricePointId: usaPoint.id,
      customerPrice: usaPrice,
    },
    ...equalized.map((pp) => ({
      territory: pp.relationships?.territory?.data?.id,
      pricePointId: pp.id,
      customerPrice: pp.attributes?.customerPrice,
    })),
  ].filter((t) => t.territory && t.pricePointId);

  const needsWrite =
    targets.length !== currentByTerritory.size ||
    targets.some((t) => {
      const cur = currentByTerritory.get(t.territory);
      return !cur || String(cur.customerPrice) !== String(t.customerPrice);
    });

  if (!needsWrite) {
    return `ok territories=${targets.length} USA=$${usaPrice}`;
  }

  if (dryRun) {
    return `would bulk-set ${targets.length} territories USA=$${usaPrice} (have ${currentByTerritory.size})`;
  }

  const included = targets.map((t, i) => ({
    type: 'subscriptionPrices',
    id: `\${price${i}}`,
    attributes: { startDate: null, planType: PLAN_TYPE },
    relationships: {
      subscriptionPricePoint: {
        data: {
          type: 'subscriptionPricePoints',
          id: t.pricePointId,
        },
      },
      territory: {
        data: { type: 'territories', id: t.territory },
      },
    },
  }));

  await ascFetch(token, `/subscriptions/${sub.id}`, {
    method: 'PATCH',
    body: {
      data: {
        type: 'subscriptions',
        id: sub.id,
        relationships: {
          prices: {
            data: included.map((p) => ({
              type: 'subscriptionPrices',
              id: p.id,
            })),
          },
        },
      },
      included,
    },
  });

  return `bulk-set ${targets.length} territories USA=$${usaPrice}`;
}

async function ensureLocalizations(token, sub, localizations, dryRun) {
  const existing = await ascListAll(
    token,
    `/subscriptions/${sub.id}/subscriptionLocalizations?limit=50`,
  );
  const byLocale = new Map(
    existing.map((l) => [l.attributes?.locale, l]),
  );

  let created = 0;
  let updated = 0;
  let skipped = 0;

  for (const [locale, fields] of Object.entries(localizations)) {
    const name = fields.name;
    const description = fields.description;
    const cur = byLocale.get(locale);
    if (
      cur &&
      cur.attributes?.name === name &&
      cur.attributes?.description === description
    ) {
      skipped += 1;
      continue;
    }
    if (!cur) {
      created += 1;
      if (dryRun) continue;
      await ascFetch(token, `/subscriptionLocalizations`, {
        method: 'POST',
        body: {
          data: {
            type: 'subscriptionLocalizations',
            attributes: { locale, name, description },
            relationships: {
              subscription: {
                data: { type: 'subscriptions', id: sub.id },
              },
            },
          },
        },
      });
      continue;
    }
    updated += 1;
    if (dryRun) continue;
    await ascFetch(token, `/subscriptionLocalizations/${cur.id}`, {
      method: 'PATCH',
      body: {
        data: {
          type: 'subscriptionLocalizations',
          id: cur.id,
          attributes: { name, description },
        },
      },
    });
  }

  return dryRun
    ? `would create=${created} update=${updated} skip=${skipped}`
    : `created=${created} updated=${updated} skip=${skipped}`;
}

async function pollAsset(token, typePath, id, { timeoutMs = 60_000 } = {}) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const cur = await ascFetch(token, `/${typePath}/${id}`);
    const state =
      cur.data?.attributes?.assetDeliveryState?.state ||
      cur.data?.attributes?.state;
    if (state === 'COMPLETE' || state === 'PREPARE_FOR_SUBMISSION') {
      return cur.data;
    }
    if (state === 'FAILED') {
      const errors = cur.data?.attributes?.assetDeliveryState?.errors;
      throw new Error(
        `Asset ${id} FAILED: ${JSON.stringify(errors ?? cur.data?.attributes)}`,
      );
    }
    await sleep(1200);
  }
  throw new Error(`Asset ${id} timed out waiting for COMPLETE`);
}

async function ensurePromoImage(token, sub, imagePath, dryRun) {
  if (!fs.existsSync(imagePath)) {
    return `missing file ${imagePath}`;
  }
  const existing = await ascFetch(
    token,
    `/subscriptions/${sub.id}/images`,
  ).catch(() => ({ data: [] }));
  const current = (existing.data ?? [])[0];
  if (current?.attributes?.imageAsset?.width === 1024) {
    return `ok ${current.id}`;
  }

  if (dryRun) {
    return `would upload ${path.basename(imagePath)}`;
  }

  for (const img of existing.data ?? []) {
    await ascFetch(token, `/subscriptionImages/${img.id}`, {
      method: 'DELETE',
    }).catch(() => {});
  }

  const buf = fs.readFileSync(imagePath);
  const reserved = await ascFetch(token, `/subscriptionImages`, {
    method: 'POST',
    body: {
      data: {
        type: 'subscriptionImages',
        attributes: {
          fileName: path.basename(imagePath),
          fileSize: buf.length,
        },
        relationships: {
          subscription: {
            data: { type: 'subscriptions', id: sub.id },
          },
        },
      },
    },
  });
  await uploadAscAsset(buf, reserved.data.attributes.uploadOperations);
  await ascFetch(token, `/subscriptionImages/${reserved.data.id}`, {
    method: 'PATCH',
    body: {
      data: {
        type: 'subscriptionImages',
        id: reserved.data.id,
        attributes: {
          uploaded: true,
          sourceFileChecksum: md5File(buf),
        },
      },
    },
  });
  await pollAsset(token, 'subscriptionImages', reserved.data.id);
  return `uploaded ${reserved.data.id}`;
}

async function ensureReviewScreenshot(token, sub, imagePath, dryRun) {
  if (!fs.existsSync(imagePath)) {
    return `missing file ${imagePath} (run generate-review-shots.sh)`;
  }

  const existing = await ascFetch(
    token,
    `/subscriptions/${sub.id}/appStoreReviewScreenshot`,
  ).catch(() => ({ data: null }));

  const state = existing.data?.attributes?.assetDeliveryState?.state;
  if (existing.data?.id && state === 'COMPLETE') {
    return `ok ${existing.data.id}`;
  }

  if (dryRun) {
    return `would upload ${path.basename(imagePath)}`;
  }

  if (existing.data?.id) {
    await ascFetch(
      token,
      `/subscriptionAppStoreReviewScreenshots/${existing.data.id}`,
      { method: 'DELETE' },
    ).catch(() => {});
  }

  const buf = fs.readFileSync(imagePath);
  const reserved = await ascFetch(
    token,
    `/subscriptionAppStoreReviewScreenshots`,
    {
      method: 'POST',
      body: {
        data: {
          type: 'subscriptionAppStoreReviewScreenshots',
          attributes: {
            fileName: path.basename(imagePath),
            fileSize: buf.length,
          },
          relationships: {
            subscription: {
              data: { type: 'subscriptions', id: sub.id },
            },
          },
        },
      },
    },
  );
  await uploadAscAsset(buf, reserved.data.attributes.uploadOperations);
  await ascFetch(
    token,
    `/subscriptionAppStoreReviewScreenshots/${reserved.data.id}`,
    {
      method: 'PATCH',
      body: {
        data: {
          type: 'subscriptionAppStoreReviewScreenshots',
          id: reserved.data.id,
          attributes: {
            uploaded: true,
            sourceFileChecksum: md5File(buf),
          },
        },
      },
    },
  );
  await pollAsset(
    token,
    'subscriptionAppStoreReviewScreenshots',
    reserved.data.id,
  );
  return `uploaded ${reserved.data.id}`;
}

async function ensureRetentionMessage(token, appId, dryRun) {
  const cfg = RETENTION_MESSAGE;
  const messages = await ascListAll(
    token,
    `/apps/${appId}/retentionMessages?limit=20`,
  );
  let message = messages.find(
    (m) => m.attributes?.referenceName === cfg.referenceName,
  );

  if (!message) {
    if (dryRun) {
      return { messageId: null, summary: `would create ${cfg.referenceName}` };
    }
    const created = await ascFetch(token, `/retentionMessages`, {
      method: 'POST',
      body: {
        data: {
          type: 'retentionMessages',
          attributes: { referenceName: cfg.referenceName },
          relationships: {
            app: { data: { type: 'apps', id: appId } },
          },
        },
      },
    });
    message = created.data;
  }

  const versions = await ascListAll(
    token,
    `/retentionMessages/${message.id}/versions?limit=20`,
  );
  let version = versions.find((v) =>
    MUTABLE_RETENTION_STATES.has(v.attributes?.state),
  );

  async function localizationMatches(versionId) {
    const locs = await ascListAll(
      token,
      `/retentionMessageVersions/${versionId}/localizations?limit=50`,
    );
    const byLocale = new Map(locs.map((l) => [l.attributes?.locale, l]));
    for (const [locale, fields] of Object.entries(cfg.localizations)) {
      const cur = byLocale.get(locale);
      if (
        !cur ||
        cur.attributes?.header !== fields.header ||
        cur.attributes?.body !== fields.body
      ) {
        return { match: false, locs };
      }
    }
    return { match: true, locs };
  }

  // If no draft version, reuse latest when copy already matches; else open a new draft.
  // READY_FOR_REVIEW / APPROVED versions are immutable — Apple also blocks a second
  // unreleased version, so fall back to a new retentionMessages resource.
  if (!version) {
    const latest = versions[0];
    if (latest) {
      const check = await localizationMatches(latest.id);
      if (check.match) {
        return {
          messageId: message.id,
          summary: `ok copy (${cfg.referenceName}, state=${latest.attributes?.state})`,
        };
      }
    }
    if (dryRun) {
      return {
        messageId: message.id,
        summary: `would create version + locs for ${cfg.referenceName}`,
      };
    }
    try {
      const created = await ascFetch(token, `/retentionMessageVersions`, {
        method: 'POST',
        body: {
          data: {
            type: 'retentionMessageVersions',
            relationships: {
              retentionMessage: {
                data: { type: 'retentionMessages', id: message.id },
              },
            },
          },
        },
      });
      version = created.data;
    } catch (error) {
      const detail = String(error.message || error);
      if (!detail.includes('STATE_ERROR.ALREADY_EXISTS')) throw error;
      const stamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
      const nextName = `${cfg.referenceName}-${stamp}`;
      const createdMsg = await ascFetch(token, `/retentionMessages`, {
        method: 'POST',
        body: {
          data: {
            type: 'retentionMessages',
            attributes: { referenceName: nextName },
            relationships: {
              app: { data: { type: 'apps', id: appId } },
            },
          },
        },
      });
      message = createdMsg.data;
      const createdVer = await ascFetch(token, `/retentionMessageVersions`, {
        method: 'POST',
        body: {
          data: {
            type: 'retentionMessageVersions',
            relationships: {
              retentionMessage: {
                data: {
                  type: 'retentionMessages',
                  id: message.id,
                },
              },
            },
          },
        },
      });
      version = createdVer.data;
      console.log(
        `  note: prior version locked; created ${nextName} instead`,
      );
    }
  }

  const existing = await ascListAll(
    token,
    `/retentionMessageVersions/${version.id}/localizations?limit=50`,
  );
  const byLocale = new Map(existing.map((l) => [l.attributes?.locale, l]));
  let created = 0;
  let updated = 0;
  let skipped = 0;

  for (const [locale, fields] of Object.entries(cfg.localizations)) {
    const cur = byLocale.get(locale);
    if (
      cur &&
      cur.attributes?.header === fields.header &&
      cur.attributes?.body === fields.body
    ) {
      skipped += 1;
      continue;
    }
    if (!cur) {
      created += 1;
      if (dryRun) continue;
      await ascFetch(token, `/retentionMessageLocalizations`, {
        method: 'POST',
        body: {
          data: {
            type: 'retentionMessageLocalizations',
            attributes: {
              locale,
              header: fields.header,
              body: fields.body,
            },
            relationships: {
              retentionMessageVersion: {
                data: {
                  type: 'retentionMessageVersions',
                  id: version.id,
                },
              },
            },
          },
        },
      });
      continue;
    }
    updated += 1;
    if (dryRun) continue;
    await ascFetch(token, `/retentionMessageLocalizations/${cur.id}`, {
      method: 'PATCH',
      body: {
        data: {
          type: 'retentionMessageLocalizations',
          id: cur.id,
          attributes: { header: fields.header, body: fields.body },
        },
      },
    });
  }

  const summary = dryRun
    ? `would locs create=${created} update=${updated} skip=${skipped} (${cfg.referenceName})`
    : `locs created=${created} updated=${updated} skip=${skipped} (${cfg.referenceName})`;
  return { messageId: message.id, summary };
}

async function ensureSubscriptionGroupLocalizations(token, appId, dryRun) {
  const groups = await ascListAll(
    token,
    `/apps/${appId}/subscriptionGroups?limit=50`,
  );
  if (groups.length === 0) return 'no subscription groups';

  const summaries = [];
  for (const group of groups) {
    const groupName = group.attributes?.referenceName ?? group.id;
    const existing = await ascListAll(
      token,
      `/subscriptionGroups/${group.id}/subscriptionGroupLocalizations?limit=50`,
    );
    const byLocale = new Map(
      existing.map((l) => [l.attributes?.locale, l]),
    );
    let created = 0;
    let updated = 0;
    let skipped = 0;

    for (const [locale, fields] of Object.entries(
      SUBSCRIPTION_GROUP_LOCALIZATIONS,
    )) {
      const cur = byLocale.get(locale);
      if (
        cur &&
        cur.attributes?.name === fields.name &&
        (cur.attributes?.customAppName ?? null) ===
          (fields.customAppName ?? null)
      ) {
        skipped += 1;
        continue;
      }
      if (!cur) {
        created += 1;
        if (dryRun) continue;
        await ascFetch(token, `/subscriptionGroupLocalizations`, {
          method: 'POST',
          body: {
            data: {
              type: 'subscriptionGroupLocalizations',
              attributes: {
                locale,
                name: fields.name,
                customAppName: fields.customAppName,
              },
              relationships: {
                subscriptionGroup: {
                  data: { type: 'subscriptionGroups', id: group.id },
                },
              },
            },
          },
        });
        continue;
      }
      updated += 1;
      if (dryRun) continue;
      await ascFetch(token, `/subscriptionGroupLocalizations/${cur.id}`, {
        method: 'PATCH',
        body: {
          data: {
            type: 'subscriptionGroupLocalizations',
            id: cur.id,
            attributes: {
              name: fields.name,
              customAppName: fields.customAppName,
            },
          },
        },
      });
    }

    summaries.push(
      dryRun
        ? `${groupName}: would create=${created} update=${updated} skip=${skipped}`
        : `${groupName}: created=${created} updated=${updated} skip=${skipped}`,
    );
  }
  return summaries.join('; ');
}

async function ensureRetentionAssignment(token, sub, messageId, dryRun) {
  if (!messageId) {
    return dryRun ? 'would assign (message pending)' : 'skip (no message)';
  }
  const current = await ascFetch(
    token,
    `/subscriptions/${sub.id}/retentionMessage`,
  ).catch(() => ({ data: null }));
  if (current.data?.id === messageId) {
    return `ok ${current.data.attributes?.referenceName ?? messageId}`;
  }
  if (dryRun) {
    return `would assign ${messageId}`;
  }
  await ascFetch(token, `/subscriptions/${sub.id}/relationships/retentionMessage`, {
    method: 'PATCH',
    body: {
      data: { type: 'retentionMessages', id: messageId },
    },
  });
  return `assigned ${messageId}`;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(`Usage: set-subscription-details.sh [--dry-run] [--only a,b] [--product id]

Steps: ${ALL_STEPS.join(', ')}`);
    return;
  }

  for (const step of args.only) {
    if (!ALL_STEPS.includes(step)) {
      throw new Error(`Unknown --only step: ${step}`);
    }
  }

  const env = requireAscEnv(__dirname);
  const appId = await resolveAppId(env.token, env);
  console.log(`App: ${appId} (${env.bundleId})`);
  if (args.dryRun) console.log('Mode: dry-run\n');

  const needTerritories =
    args.only.has('availability') || args.only.has('prices');
  const territories = needTerritories
    ? await loadTerritories(env.token)
    : [];
  if (needTerritories) console.log(`Territories: ${territories.length}`);

  const byProduct = await indexSubscriptions(env.token, appId);
  const wanted = Object.entries(SUBSCRIPTIONS).filter(([productId]) =>
    args.products ? args.products.has(productId) : true,
  );

  let retentionMessageId = null;
  if (args.only.has('retention')) {
    const result = await ensureRetentionMessage(
      env.token,
      appId,
      args.dryRun,
    );
    retentionMessageId = result.messageId;
    console.log(`\nRetention message: ${result.summary}`);
  }

  if (args.only.has('groupLocalizations')) {
    const msg = await ensureSubscriptionGroupLocalizations(
      env.token,
      appId,
      args.dryRun,
    );
    console.log(`\nGroup localizations: ${msg}`);
  }

  for (const [productId, cfg] of wanted) {
    const sub = byProduct.get(productId);
    console.log(`\n=== ${productId}`);
    if (!sub) {
      console.log('  MISSING in ASC');
      continue;
    }
    console.log(
      `  id=${sub.id} state=${sub.attributes?.state} period=${sub.attributes?.subscriptionPeriod}`,
    );

    if (args.only.has('availability')) {
      const msg = await ensureAvailability(
        env.token,
        sub,
        territories,
        args.dryRun,
      );
      console.log(`  availability  ${msg}`);
    }
    if (args.only.has('prices')) {
      const msg = await ensurePrices(
        env.token,
        sub,
        cfg.usaPrice,
        args.dryRun,
      );
      console.log(`  prices        ${msg}`);
    }
    if (args.only.has('localizations')) {
      const msg = await ensureLocalizations(
        env.token,
        sub,
        cfg.localizations,
        args.dryRun,
      );
      console.log(`  localizations ${msg}`);
    }
    if (args.only.has('promo')) {
      const msg = await ensurePromoImage(
        env.token,
        sub,
        cfg.promoImage,
        args.dryRun,
      );
      console.log(`  promo         ${msg}`);
    }
    if (args.only.has('review')) {
      const msg = await ensureReviewScreenshot(
        env.token,
        sub,
        cfg.reviewScreenshot,
        args.dryRun,
      );
      console.log(`  review        ${msg}`);
    }
    if (args.only.has('retention')) {
      const msg = await ensureRetentionAssignment(
        env.token,
        sub,
        retentionMessageId,
        args.dryRun,
      );
      console.log(`  retention     ${msg}`);
    }
  }

  console.log('\nDone.');
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
