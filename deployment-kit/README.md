# Deployment Kit — ClipGo

배포 직전마다 AI에게 여러 번 설명하지 않도록 만든 단일 폴더입니다.

## 구조

```
deployment-kit/
├── app-config.json              # ClipGo 설정 (bundle id, URL, 키 경로)
├── app-config.example.json
├── asc-metadata/                # App Store Connect 메타데이터
├── play-metadata/               # Google Play 메타데이터
├── build_android.sh
├── build_ios.sh
├── upload_ios_metadata.sh
├── upload_android_metadata.sh
├── release_all.sh
├── release_ios_all.sh
└── release_android_all.sh
```

> 스크립트는 `deployment-kit/` 바로 아래에 둡니다 (`scripts/` 하위가 아님).

## 사용법

`client/` 에서:

```bash
# iOS 전체 (메타 + 빌드)
./deployment-kit/release_ios_all.sh

# Android 전체 (빌드 + 메타)
./deployment-kit/release_android_all.sh

# 개별 실행
./deployment-kit/upload_ios_metadata.sh --dry-run
./deployment-kit/upload_android_metadata.sh --dry-run
./deployment-kit/build_ios.sh --bump
./deployment-kit/build_android.sh
```

## 설정 파일

- `app-config.json`: 앱명, bundle/package id, URL, 키 경로, review contact
- `asc-metadata/listings.mjs`: App Store 문구
- `asc-metadata/store-urls.mjs`: privacy / support / marketing / copyright (`app-config.json` 기반)
- `play-metadata/`: Play 업로드 (문구는 `asc-metadata/listings.mjs` 재사용)

자세한 내용은 `asc-metadata/README.md`, `play-metadata/README.md` 참고.
