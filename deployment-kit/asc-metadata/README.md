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
