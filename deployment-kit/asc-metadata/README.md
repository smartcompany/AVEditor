# App Store Connect — 메타데이터 업로드 (Remember Where)

문구 파일을 수정한 뒤 스크립트로 App Store Connect에 반영합니다.

- **Bundle ID:** `com.smartcompany.AIFindProducts`
- **영문 앱명:** Remember Where
- **한국어 앱명:** 어디있더라?

## 파일

### `listings.mjs`
로케일별 스토어 문구.

### `store-urls.mjs`
`../app-config.json` 기반 `privacyUrl`, `supportUrl`, `marketingUrl`, `copyright`.

### `whats-new.json`
버전별 새로운 기능.

### `review-notes.txt`
심사팀용 App Review Notes (4000 bytes 제한).

## 1회 설정

```bash
cd client/deployment-kit/asc-metadata
cp .env.example .env
# ASC_ISSUER_ID=...
```

Review contact는 `../app-config.json` 또는 `.env`의 `ASC_REVIEW_CONTACT_*` 로 설정됩니다.

## 사용

`client/` 에서:

```bash
./deployment-kit/scripts/upload_ios_metadata.sh --dry-run
./deployment-kit/scripts/upload_ios_metadata.sh
./deployment-kit/scripts/upload_ios_metadata.sh --only reviewNotes
```

또는 이 폴더에서:

```bash
cd client/deployment-kit/asc-metadata
./update-metadata.sh --dry-run
./update-whats-new.sh
```

## 구독 상세 (Subscription detail)

ASC 구독 상세 화면의 사용 가능 여부 / 가격 / 표시 이름·설명 / 1024 프로모 이미지 / 심사 스크린샷을 API로 채웁니다.

설정 파일: `subscriptions.mjs`  
에셋: `docs/store-assets/*-1024.png` → 심사 JPG는 `generate-review-shots.sh`가 `docs/store-assets/review/`에 생성

```bash
cd client/deployment-kit/asc-metadata
./set-subscription-levels.sh --dry-run          # groupLevel
./set-subscription-details.sh --dry-run         # 상세 설정
./set-subscription-details.sh                   # 적용
./set-subscription-details.sh --only localizations,promo
./set-subscription-details.sh --only retention  # 유지 메시지(공통 문구)
./set-subscription-details.sh --only groupLocalizations  # 구독 그룹 표시 이름
./set-subscription-details.sh --product com.smartcompany.aveditor.studio.annual
```

유지 메시지 / 구독 그룹 표시 이름은 `subscriptions.mjs`의
`RETENTION_MESSAGE`, `SUBSCRIPTION_GROUP_LOCALIZATIONS`에서 수정합니다.

### 심사 초안 (첫 구독 제출)

첫 자동 갱신 구독은 **앱 버전 + 구독 그룹 + 구독**이 같은 초안에 있어야 합니다.

```bash
./prepare-subscription-review.sh --dry-run
./prepare-subscription-review.sh
```

앱 버전 첨부가 막히면 보통 **App Privacy(데이터 수집 답변 게시)** 또는
**iPhone 스크린샷**이 원인입니다. 스크립트가 남은 차단 사유를 출력합니다.
