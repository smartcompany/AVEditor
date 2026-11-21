#!/usr/bin/env node
/**
 * Fill the ASC Review Submission draft so first-time subscriptions can submit:
 *   - all subscription versions
 *   - subscription group version
 *   - retention message version (if present)
 *   - iOS appStoreVersion (when the version is review-ready)
 *
 * Also applies common blockers we can fix via API:
 *   - primaryCategory PHOTO_AND_VIDEO
 *   - contentRightsDeclaration
 *   - ageRatingDeclaration safe defaults
 *
 * Usage:
 *   ./prepare-subscription-review.sh
 *   ./prepare-subscription-review.sh --dry-run
 *   ./prepare-subscription-review.sh --submit   # marks draft submitted=true
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  EDITABLE_STATES,
  ascFetch,
  ascListAll,
  requireAscEnv,
  resolveAppId,
  resolveIosVersion,
  sleep,
  uploadAscAsset,
} from './lib/asc.mjs';
import { RETENTION_MESSAGE, SUBSCRIPTIONS } from './subscriptions.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '../../..');
const SCREENSHOT_DIR = path.join(ROOT, 'docs/store-assets/app-screenshots');

const DRAFT_STATES = new Set([
  'READY_FOR_REVIEW',
  'UNRESOLVED_ISSUES',
  'WAITING_FOR_REVIEW',
]);

function parseArgs(argv) {
  return {
    dryRun: argv.includes('--dry-run'),
    submit: argv.includes('--submit'),
  };
}

function md5File(buf) {
  return crypto.createHash('md5').update(buf).digest('hex');
}

async function ensureReviewSubmission(token, appId, dryRun) {
  const existing = await ascListAll(
    token,
    `/apps/${appId}/reviewSubmissions?limit=20`,
  );
  const draft = existing.find((s) =>
    ['READY_FOR_REVIEW', 'UNRESOLVED_ISSUES'].includes(s.attributes?.state),
  );
  if (draft) return draft;
  if (dryRun) {
    console.log('Would create IOS reviewSubmission');
    return null;
  }
  const created = await ascFetch(token, `/reviewSubmissions`, {
    method: 'POST',
    body: {
      data: {
        type: 'reviewSubmissions',
        attributes: { platform: 'IOS' },
        relationships: {
          app: { data: { type: 'apps', id: appId } },
        },
      },
    },
  });
  return created.data;
}

async function listSubmissionItemTargets(token, submissionId) {
  const json = await ascFetch(
    token,
    `/reviewSubmissions/${submissionId}/items?limit=200&include=appStoreVersion,subscriptionVersion,subscriptionGroupVersion,retentionMessageVersion`,
  );
  const have = {
    appStoreVersion: new Set(),
    subscriptionVersion: new Set(),
    subscriptionGroupVersion: new Set(),
    retentionMessageVersion: new Set(),
  };
  for (const item of json.data ?? []) {
    for (const key of Object.keys(have)) {
      const id = item.relationships?.[key]?.data?.id;
      if (id) have[key].add(id);
    }
  }
  return { items: json.data ?? [], have };
}

async function addItem(token, submissionId, relationshipKey, type, id, dryRun) {
  if (dryRun) {
    console.log(`  would add ${relationshipKey}=${id}`);
    return 'would-add';
  }
  await ascFetch(token, `/reviewSubmissionItems`, {
    method: 'POST',
    body: {
      data: {
        type: 'reviewSubmissionItems',
        relationships: {
          reviewSubmission: {
            data: { type: 'reviewSubmissions', id: submissionId },
          },
          [relationshipKey]: { data: { type, id } },
        },
      },
    },
  });
  return 'added';
}

async function ensureAppBasics(token, appId, dryRun) {
  const infos = await ascFetch(token, `/apps/${appId}/appInfos`);
  const info =
    (infos.data ?? []).find((i) =>
      EDITABLE_STATES.has(i.attributes?.appStoreState),
    ) || infos.data?.[0];
  if (!info) return 'no appInfo';

  const primary = await ascFetch(
    token,
    `/appInfos/${info.id}/primaryCategory`,
  ).catch(() => ({ data: null }));
  if (!primary.data) {
    if (dryRun) console.log('  would set primaryCategory=PHOTO_AND_VIDEO');
    else {
      await ascFetch(token, `/appInfos/${info.id}`, {
        method: 'PATCH',
        body: {
          data: {
            type: 'appInfos',
            id: info.id,
            relationships: {
              primaryCategory: {
                data: { type: 'appCategories', id: 'PHOTO_AND_VIDEO' },
              },
            },
          },
        },
      });
      console.log('  set primaryCategory=PHOTO_AND_VIDEO');
    }
  } else {
    console.log(`  primaryCategory ok (${primary.data.id})`);
  }

  const app = await ascFetch(token, `/apps/${appId}`);
  if (!app.data?.attributes?.contentRightsDeclaration) {
    if (dryRun) {
      console.log('  would set contentRightsDeclaration');
    } else {
      await ascFetch(token, `/apps/${appId}`, {
        method: 'PATCH',
        body: {
          data: {
            type: 'apps',
            id: appId,
            attributes: {
              contentRightsDeclaration: 'DOES_NOT_USE_THIRD_PARTY_CONTENT',
            },
          },
        },
      });
      console.log('  set contentRightsDeclaration');
    }
  } else {
    console.log(
      `  contentRights ok (${app.data.attributes.contentRightsDeclaration})`,
    );
  }

  const age = await ascFetch(
    token,
    `/appInfos/${info.id}/ageRatingDeclaration`,
  ).catch(() => ({ data: null }));
  if (age.data?.id) {
    const NONE = 'NONE';
    const attrs = {
      alcoholTobaccoOrDrugUseOrReferences: NONE,
      contests: NONE,
      gambling: false,
      gamblingSimulated: NONE,
      medicalOrTreatmentInformation: NONE,
      profanityOrCrudeHumor: NONE,
      sexualContentGraphicAndNudity: NONE,
      sexualContentOrNudity: NONE,
      horrorOrFearThemes: NONE,
      matureOrSuggestiveThemes: NONE,
      unrestrictedWebAccess: false,
      violenceCartoonOrFantasy: NONE,
      violenceRealistic: NONE,
      violenceRealisticProlongedGraphicOrSadistic: NONE,
      gunsOrOtherWeapons: NONE,
      advertising: false,
      parentalControls: false,
      userGeneratedContent: false,
      ageAssurance: false,
      lootBox: false,
      socialMedia: false,
      healthOrWellnessTopics: false,
      messagingAndChat: false,
      datingAndRelationships: false,
      sharedLocation: false,
    };
    const patch = {};
    for (const [k, v] of Object.entries(attrs)) {
      if (age.data.attributes?.[k] == null) patch[k] = v;
    }
    if (Object.keys(patch).length) {
      if (dryRun) {
        console.log(
          `  would fill ageRatingDeclaration (${Object.keys(patch).length} fields)`,
        );
      } else {
        try {
          await ascFetch(token, `/ageRatingDeclarations/${age.data.id}`, {
            method: 'PATCH',
            body: {
              data: {
                type: 'ageRatingDeclarations',
                id: age.data.id,
                attributes: patch,
              },
            },
          });
          console.log(
            `  filled ageRatingDeclaration (${Object.keys(patch).length} fields)`,
          );
        } catch (error) {
          console.log(
            `  ageRatingDeclaration warn: ${String(error.message).split('\n')[0]}`,
          );
        }
      }
    } else {
      console.log('  ageRatingDeclaration ok');
    }
  }

  return info.id;
}

async function ensureIphoneScreenshots(token, appVersionId, dryRun) {
  const file69 = path.join(SCREENSHOT_DIR, 'iphone-6-9.png');
  if (!fs.existsSync(file69)) {
    return `missing ${file69}`;
  }

  const locs = await ascListAll(
    token,
    `/appStoreVersions/${appVersionId}/appStoreVersionLocalizations?limit=50`,
  );
  const en = locs.find((l) => l.attributes?.locale === 'en-US') || locs[0];
  if (!en) return 'no version localization';

  const displayType = 'APP_IPHONE_67';
  let sets = [];
  try {
    sets = await ascListAll(
      token,
      `/appStoreVersionLocalizations/${en.id}/appScreenshotSets?limit=20`,
    );
  } catch {
    // relationship name varies on older API paths
    sets = [];
  }

  let set = sets.find(
    (s) => s.attributes?.screenshotDisplayType === displayType,
  );
  if (!set) {
    // try alternate type names used by Dynamic Island requirement
    for (const t of ['APP_IPHONE_67', 'APP_IPHONE_69', 'APP_IPHONE_65']) {
      set = sets.find((s) => s.attributes?.screenshotDisplayType === t);
      if (set) break;
    }
  }

  if (!set) {
    if (dryRun) return `would create screenshot set ${displayType}`;
    try {
      const created = await ascFetch(token, `/appScreenshotSets`, {
        method: 'POST',
        body: {
          data: {
            type: 'appScreenshotSets',
            attributes: { screenshotDisplayType: displayType },
            relationships: {
              appStoreVersionLocalization: {
                data: {
                  type: 'appStoreVersionLocalizations',
                  id: en.id,
                },
              },
            },
          },
        },
      });
      set = created.data;
    } catch (error) {
      return `screenshot set create failed: ${String(error.message).slice(0, 180)}`;
    }
  }

  const existing = await ascListAll(
    token,
    `/appScreenshotSets/${set.id}/appScreenshots?limit=20`,
  );
  if (existing.some((s) => s.attributes?.imageAsset?.width)) {
    return `ok screenshots=${existing.length} (${set.attributes?.screenshotDisplayType})`;
  }

  if (dryRun) return `would upload ${path.basename(file69)}`;

  const buf = fs.readFileSync(file69);
  const reserved = await ascFetch(token, `/appScreenshots`, {
    method: 'POST',
    body: {
      data: {
        type: 'appScreenshots',
        attributes: {
          fileName: path.basename(file69),
          fileSize: buf.length,
        },
        relationships: {
          appScreenshotSet: {
            data: { type: 'appScreenshotSets', id: set.id },
          },
        },
      },
    },
  });
  await uploadAscAsset(buf, reserved.data.attributes.uploadOperations);
  await ascFetch(token, `/appScreenshots/${reserved.data.id}`, {
    method: 'PATCH',
    body: {
      data: {
        type: 'appScreenshots',
        id: reserved.data.id,
        attributes: {
          uploaded: true,
          sourceFileChecksum: md5File(buf),
        },
      },
    },
  });
  for (let i = 0; i < 15; i += 1) {
    await sleep(1200);
    const cur = await ascFetch(token, `/appScreenshots/${reserved.data.id}`);
    const state = cur.data?.attributes?.assetDeliveryState?.state;
    if (state === 'COMPLETE') {
      return `uploaded screenshot ${reserved.data.id}`;
    }
    if (state === 'FAILED') {
      throw new Error(
        `screenshot FAILED ${JSON.stringify(cur.data?.attributes?.assetDeliveryState)}`,
      );
    }
  }
  return `uploaded screenshot ${reserved.data.id} (processing)`;
}

async function collectSubscriptionVersions(token, appId) {
  const groups = await ascListAll(
    token,
    `/apps/${appId}/subscriptionGroups?limit=50`,
  );
  const subscriptions = [];
  let groupVersionId = null;
  let groupId = null;
  for (const group of groups) {
    const gVers = await ascListAll(
      token,
      `/subscriptionGroups/${group.id}/versions?limit=10`,
    );
    const groupVersion =
      gVers.find((v) =>
        ['PREPARE_FOR_SUBMISSION', 'READY_FOR_REVIEW'].includes(
          v.attributes?.state,
        ),
      ) || gVers[0];
    if (groupVersion) {
      groupVersionId = groupVersion.id;
      groupId = group.id;
    }

    const subs = await ascListAll(
      token,
      `/subscriptionGroups/${group.id}/subscriptions?limit=50`,
    );
    for (const sub of subs) {
      const productId = sub.attributes?.productId;
      if (!SUBSCRIPTIONS[productId]) continue;
      const vers = await ascListAll(
        token,
        `/subscriptions/${sub.id}/versions?limit=10`,
      );
      const version = vers[0];
      if (version) {
        subscriptions.push({
          productId,
          subscriptionVersionId: version.id,
        });
      }
    }
  }
  return { subscriptions, groupVersionId, groupId };
}

async function findRetentionVersion(token, appId) {
  const msgs = await ascListAll(
    token,
    `/apps/${appId}/retentionMessages?limit=20`,
  );
  const msg =
    msgs.find(
      (m) => m.attributes?.referenceName === RETENTION_MESSAGE.referenceName,
    ) || msgs[0];
  if (!msg) return null;
  const vers = await ascListAll(
    token,
    `/retentionMessages/${msg.id}/versions?limit=10`,
  );
  return (
    vers.find((v) =>
      ['PREPARE_FOR_SUBMISSION', 'READY_FOR_REVIEW'].includes(
        v.attributes?.state,
      ),
    ) || vers[0]
  );
}

function summarizeAssociatedErrors(error) {
  const text = String(error.message || error);
  const details = [...text.matchAll(/"detail":\s*"([^"]+)"/g)].map((m) => m[1]);
  const codes = [...text.matchAll(/"code":\s*"([^"]+)"/g)].map((m) => m[1]);
  return {
    codes: [...new Set(codes)].filter(
      (c) => c !== 'STATE_ERROR.ENTITY_STATE_INVALID',
    ),
    details: [...new Set(details)].filter(
      (d) => !d.includes('associated errors'),
    ),
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const env = requireAscEnv(__dirname);
  const appId = await resolveAppId(env.token, env);
  console.log(`App: ${appId} (${env.bundleId})`);
  if (args.dryRun) console.log('Mode: dry-run\n');

  console.log('\n== App basics');
  await ensureAppBasics(env.token, appId, args.dryRun);

  const iosVersion = await resolveIosVersion(env.token, appId);
  console.log(
    `\nApp Store version: ${iosVersion.attributes?.versionString} (${iosVersion.attributes?.appStoreState}) id=${iosVersion.id}`,
  );

  console.log('\n== Screenshots');
  const shotMsg = await ensureIphoneScreenshots(
    env.token,
    iosVersion.id,
    args.dryRun,
  );
  console.log(`  ${shotMsg}`);

  console.log('\n== Review submission draft');
  const submission = await ensureReviewSubmission(
    env.token,
    appId,
    args.dryRun,
  );
  if (!submission) {
    console.log('No submission draft (dry-run).');
    return;
  }
  console.log(
    `Submission: ${submission.id} state=${submission.attributes?.state}`,
  );

  const { have } = await listSubmissionItemTargets(env.token, submission.id);
  const { subscriptions, groupVersionId } = await collectSubscriptionVersions(
    env.token,
    appId,
  );

  if (groupVersionId) {
    if (have.subscriptionGroupVersion.has(groupVersionId)) {
      console.log(`  groupVersion ok ${groupVersionId}`);
    } else {
      const r = await addItem(
        env.token,
        submission.id,
        'subscriptionGroupVersion',
        'subscriptionGroupVersions',
        groupVersionId,
        args.dryRun,
      );
      console.log(`  groupVersion ${r} ${groupVersionId}`);
    }
  } else {
    console.log('  groupVersion MISSING');
  }

  for (const row of subscriptions) {
    if (have.subscriptionVersion.has(row.subscriptionVersionId)) {
      console.log(`  subscription ok ${row.productId}`);
      continue;
    }
    const r = await addItem(
      env.token,
      submission.id,
      'subscriptionVersion',
      'subscriptionVersions',
      row.subscriptionVersionId,
      args.dryRun,
    );
    console.log(`  subscription ${r} ${row.productId}`);
  }

  const retentionVersion = await findRetentionVersion(env.token, appId);
  if (retentionVersion) {
    if (have.retentionMessageVersion.has(retentionVersion.id)) {
      console.log(`  retention ok ${retentionVersion.id}`);
    } else {
      const r = await addItem(
        env.token,
        submission.id,
        'retentionMessageVersion',
        'retentionMessageVersions',
        retentionVersion.id,
        args.dryRun,
      );
      console.log(`  retention ${r} ${retentionVersion.id}`);
    }
  }

  if (have.appStoreVersion.has(iosVersion.id)) {
    console.log(`  appStoreVersion ok ${iosVersion.id}`);
  } else {
    try {
      const r = await addItem(
        env.token,
        submission.id,
        'appStoreVersion',
        'appStoreVersions',
        iosVersion.id,
        args.dryRun,
      );
      console.log(`  appStoreVersion ${r} ${iosVersion.id}`);
    } catch (error) {
      const summary = summarizeAssociatedErrors(error);
      console.log('  appStoreVersion BLOCKED');
      for (const d of summary.details) console.log(`    - ${d}`);
      if (summary.codes.includes('STATE_ERROR.APP_DATA_USAGES_REQUIRED')) {
        console.log(
          '    → ASC → App Privacy에서 데이터 수집 답변을 게시해야 앱 버전을 초안에 넣을 수 있습니다.',
        );
      }
      if (
        summary.codes.some((c) => c.includes('SCREENSHOT_REQUIRED'))
      ) {
        console.log(
          '    → iPhone Dynamic Island / 6.7" 스크린샷이 필요합니다. docs/store-assets/app-screenshots/ 확인.',
        );
      }
    }
  }

  if (args.submit && !args.dryRun) {
    console.log('\n== Submit');
    await ascFetch(env.token, `/reviewSubmissions/${submission.id}`, {
      method: 'PATCH',
      body: {
        data: {
          type: 'reviewSubmissions',
          id: submission.id,
          attributes: { submitted: true },
        },
      },
    });
    console.log('submitted=true');
  } else if (args.submit && args.dryRun) {
    console.log('\nWould submit draft');
  }

  const final = await listSubmissionItemTargets(env.token, submission.id);
  console.log(
    `\nDraft items: app=${final.have.appStoreVersion.size} group=${final.have.subscriptionGroupVersion.size} subs=${final.have.subscriptionVersion.size} retention=${final.have.retentionMessageVersion.size}`,
  );
  console.log('Done.');
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
