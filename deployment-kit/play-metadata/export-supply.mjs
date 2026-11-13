#!/usr/bin/env node
/** Write fastlane supply metadata under client/android/fastlane/metadata/android */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { readWhatsNew } from './lib/play.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const DEFAULT_OUT = path.resolve(
  __dirname,
  '../../android/fastlane/metadata/android',
);

function parseArgs(argv) {
  const args = {
    outDir: DEFAULT_OUT,
    listingsFile: path.join(__dirname, 'listings.mjs'),
    whatsNewFile: path.join(__dirname, '../asc-metadata/whats-new.json'),
    versionCode: null,
    help: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--out') args.outDir = path.resolve(argv[++i]);
    else if (a === '--listings') args.listingsFile = path.resolve(argv[++i]);
    else if (a === '--whats-new') args.whatsNewFile = path.resolve(argv[++i]);
    else if (a === '--version-code') args.versionCode = String(argv[++i]);
    else if (a === '--help' || a === '-h') args.help = true;
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(`Usage: node export-supply.mjs [options]

Writes:
  <out>/<locale>/title.txt
  <out>/<locale>/short_description.txt
  <out>/<locale>/full_description.txt
  <out>/<locale>/changelogs/<versionCode|default>.txt  (if whats-new present)

Options:
  --out DIR              Default: ../../android/fastlane/metadata/android
  --version-code N       Changelog filename (default: default.txt)
`);
    process.exit(0);
  }

  const mod = await import(pathToFileURL(path.resolve(args.listingsFile)).href);
  const listings = mod.default ?? mod.listings;
  const whatsNew = readWhatsNew(args.whatsNewFile);
  const changelogName = args.versionCode ?? 'default';

  for (const [locale, entry] of Object.entries(listings)) {
    const dir = path.join(args.outDir, locale);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'title.txt'), entry.title + '\n', 'utf8');
    fs.writeFileSync(
      path.join(dir, 'short_description.txt'),
      entry.shortDescription + '\n',
      'utf8',
    );
    fs.writeFileSync(
      path.join(dir, 'full_description.txt'),
      entry.fullDescription + '\n',
      'utf8',
    );

    const notes = whatsNew.get(locale);
    if (notes) {
      const clDir = path.join(dir, 'changelogs');
      fs.mkdirSync(clDir, { recursive: true });
      fs.writeFileSync(
        path.join(clDir, `${changelogName}.txt`),
        notes + '\n',
        'utf8',
      );
    }
    console.log(`✓ ${locale}`);
  }

  console.log(`\nWrote supply metadata → ${args.outDir}`);
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
