# Google Play — Remember Where (AIFindProducts)

Google Play Console API용 메타데이터 업로드 스크립트입니다.  
스토어 문구 원본은 `../asc-metadata/listings.mjs` 를 재사용합니다.  
URL·연락처는 `../app-config.json` 에서 읽습니다.

| App Store (ASC) | Google Play | API 업로드 |
|-----------------|-------------|------------|
| `name` | `title` (≤30자) | ✅ `edits.listings` |
| `subtitle` / `promotionalText` | `shortDescription` (≤80자) | ✅ |
| `description` | `fullDescription` (≤4000자) | ✅ |
| `supportUrl` | `contactWebsite` | ✅ `edits.details` |
| `supportEmail` / review contact | `contactEmail`, `contactPhone` | ✅ `edits.details` |
| `privacyPolicyUrl` | App content → Privacy policy | ❌ **Play Console에서 수동** |

Play 로케일: `ko-KR`, `en-US`, `ja-JP`, `zh-CN`

## 설정

```bash
cd client/deployment-kit/play-metadata
cp .env.example .env
npm install
```

`../app-config.json` 의 `serverBaseUrl`, `privacyPath`, `supportUrl`, `supportEmail`, `reviewContactPhone` 을 맞춰 두세요.

## 사용

`client/` 에서:

```bash
./deployment-kit/scripts/upload_android_metadata.sh --dry-run
./deployment-kit/scripts/upload_android_metadata.sh
./deployment-kit/scripts/upload_android_metadata.sh --only details
```

출시 노트:

```bash
cd client/deployment-kit/play-metadata
./update-whats-new.sh --version-code 5 --track production --dry-run
```

## Fastlane Supply (대안)

`export-supply.mjs` 로 `android/fastlane/metadata/android/` 생성 후 fastlane supply 사용 가능.
