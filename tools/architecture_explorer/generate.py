#!/usr/bin/env python3
"""Scan the AVEditor client and write a self-contained Architecture Explorer.

Re-run after code changes:

    python3 tools/architecture_explorer/generate.py

Output: docs/architecture.html
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]  # client/
DOCS = Path(__file__).resolve().parents[3] / "docs"
TEMPLATE = Path(__file__).resolve().parent / "index.template.html"

SCAN_DIRS = [
    ROOT / "lib",
    ROOT / "ios" / "Runner",
    ROOT / "android" / "app" / "src" / "main" / "kotlin" / "com" / "smart" / "aveditor",
]
SKIP_PARTS = {
    "l10n",
    "ephemeral",
    ".plugin_symlinks",
    "third_party",
}


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def should_scan(path: Path) -> bool:
    if path.suffix not in {".dart", ".kt", ".swift"}:
        return False
    if any(part in SKIP_PARTS for part in path.parts):
        return False
    if path.name.endswith(".g.dart"):
        return False
    return True


CLASS_RE = re.compile(
    r"^(?:abstract\s+|final\s+|internal\s+|private\s+|public\s+|open\s+)*"
    r"(?:class|object|enum|mixin|extension|data class)\s+([A-Za-z_][\w.]*)",
    re.M,
)
SWIFT_CLASS_RE = re.compile(
    r"^(?:final\s+|private\s+|public\s+)*(?:class|struct|enum|protocol)\s+([A-Za-z_][\w]*)",
    re.M,
)
DART_METHOD_RE = re.compile(
    r"^  (?! )(?:@\w+(?:\([^)]*\))?\s+)*(?:static\s+)?"
    r"(?:[\w<>,?.\[\]]+\s+)+([A-Za-z_][\w]*)\s*\(",
    re.M,
)
KT_FUN_RE = re.compile(
    r"^(?:  )?(?:override\s+|private\s+|internal\s+|public\s+|suspend\s+|open\s+)*"
    r"fun\s+([A-Za-z_][\w]*)\s*\(",
    re.M,
)
SWIFT_FUNC_RE = re.compile(
    r"^(?:    |  )?(?:private\s+|public\s+|internal\s+|static\s+|override\s+|final\s+|@\w+\s+)*"
    r"func\s+([A-Za-z_][\w]*)\s*\(",
    re.M,
)
IMPORT_DART_RE = re.compile(r"^import\s+'package:aveditor/([^']+)'", re.M)
DOC_RE = re.compile(r"^///\s?(.*)$", re.M)


def scan_file(path: Path) -> dict:
    text = path.read_text(encoding="utf-8", errors="replace")
    classes = CLASS_RE.findall(text)
    if path.suffix == ".swift":
        classes = SWIFT_CLASS_RE.findall(text) or classes
    methods: list[str] = []
    if path.suffix == ".dart":
        methods = DART_METHOD_RE.findall(text)
    elif path.suffix == ".kt":
        methods = KT_FUN_RE.findall(text)
    else:
        methods.extend(SWIFT_FUNC_RE.findall(text))
    # Drop constructors that match the class name and very common noise.
    noise = {"if", "for", "while", "switch", "return", "setState", "build"}
    cleaned = []
    seen = set()
    for name in methods:
        if name in noise or name in seen:
            continue
        if name in classes:
            continue
        seen.add(name)
        cleaned.append(name)
        if len(cleaned) >= 80:
            break
    docs = [line.strip() for line in DOC_RE.findall(text[:2500]) if line.strip()]
    imports = [f"lib/{m}" if not m.startswith("lib/") else m for m in IMPORT_DART_RE.findall(text)]
    # dart import path is already lib-relative like screens/home_screen.dart
    imports = [f"lib/{m}" for m in IMPORT_DART_RE.findall(text)]
    return {
        "path": rel(path),
        "classes": classes[:12],
        "methods": cleaned,
        "imports": imports,
        "doc": " ".join(docs[:3])[:280],
        "lines": text.count("\n") + 1,
    }


def build_tree(files: list[dict]) -> dict:
    root: dict = {"name": "client", "children": {}, "file": None}

    def ensure(node, parts):
        cur = node
        for part in parts:
            cur = cur["children"].setdefault(part, {"name": part, "children": {}, "file": None})
        return cur

    for item in files:
        parts = item["path"].split("/")
        parent = ensure(root, parts[:-1])
        parent["children"][parts[-1]] = {
            "name": parts[-1],
            "children": {},
            "file": item["path"],
        }
    return root


# Curated graph. Ids are stable. depends lists are call/import relationships
# verified by reading the current client sources. Runtime-only behavior that
# was not executed on a device in this pass is flagged on the node.
NODES = [
    {
        "id": "main",
        "name": "main / AveditorApp",
        "file": "lib/main.dart",
        "layer": "app",
        "role": "앱 진입점. 세로 고정을 걸고 카탈로그를 데운 뒤 HomeScreen을 띄운다.",
        "summary": "Flutter 앱을 시작하고 첫 화면으로 HomeScreen을 연다.",
        "does": [
            "WidgetsFlutterBinding.ensureInitialized()",
            "TextTemplatePackService.ensureInitialized()와 TransitionCatalogService.ensureInitialized()를 기다리지 않고 시작",
            "MaterialApp home: HomeScreen",
        ],
        "why": ["화면과 서비스를 직접 연결하는 작은 진입점이다. 별도의 라우터 패키지는 없다."],
        "talks": ["HomeScreen", "TransitionCatalogService", "TextTemplatePackService"],
        "readFirst": ["lib/screens/home_screen.dart"],
        "cautions": ["카탈로그 로딩 실패는 앱 시작을 막지 않는다. unawaited라서 실패는 서비스 쪽에서 처리한다."],
        "depends": ["home", "transition-catalog", "text-packs"],
        "confidence": "verified",
    },
    {
        "id": "home",
        "name": "HomeScreen",
        "file": "lib/screens/home_screen.dart",
        "layer": "screen",
        "role": "프로젝트 목록, 영상 가져오기, YouTube 로그인 상태를 담당한다.",
        "summary": "새 영상을 고르거나 저장된 프로젝트를 편집 화면으로 연다.",
        "does": [
            "_pickGallery / _pickFiles / _pickCamera → VideoImportService",
            "ProjectStorageService.createFromImport 후 EditorScreen으로 push",
            "YouTubeAuthService.signIn / signOut",
        ],
        "why": ["편집 전 단계의 유일한 홈이다. ViewModel 클래스는 없고 State가 서비스를 직접 호출한다."],
        "talks": ["VideoImportService", "ProjectStorageService", "EditorScreen", "YouTubeAuthService"],
        "readFirst": ["lib/services/video_import_service.dart", "lib/models/video_project.dart"],
        "cautions": ["앱 계정 로그인은 없다. 여기의 로그인은 YouTube OAuth다."],
        "depends": ["import", "storage", "editor", "yt-auth"],
        "confidence": "verified",
    },
    {
        "id": "import",
        "name": "VideoImportService",
        "file": "lib/services/video_import_service.dart",
        "layer": "service",
        "role": "갤러리, 파일, 카메라에서 영상 파일을 골라 앱이 열 수 있는 경로로 만든다.",
        "summary": "사용자가 고른 영상을 로컬 파일 경로로 확정한다.",
        "does": [
            "pickFromGallery()",
            "pickFromCamera()",
            "pickFromFiles()",
            "_resolveUsableVideoPath()",
        ],
        "why": ["플랫폼 피커 차이를 편집 화면 밖으로 둔다."],
        "talks": ["image_picker", "file_selector", "HomeScreen"],
        "readFirst": ["lib/screens/home_screen.dart"],
        "cautions": ["Android 갤러리 피커의 트랜스코딩 조건은 third_party/image_picker_android에 있다. 이 서비스 파일만 보면 그 분기까지는 보이지 않는다."],
        "depends": [],
        "confidence": "verified",
    },
    {
        "id": "storage",
        "name": "ProjectStorageService",
        "file": "lib/services/project_storage_service.dart",
        "layer": "service",
        "role": "프로젝트 JSON과 원본 파일을 앱 디렉터리에 저장하고 다시 읽는다.",
        "summary": "VideoProject를 디스크에 저장하는 로컬 저장소다.",
        "does": ["createFromImport()", "load()", "save()", "listSummaries()", "delete()"],
        "why": ["서버 DB가 없다. 프로젝트는 기기 로컬 파일이다."],
        "talks": ["VideoProject", "HomeScreen", "EditorScreen"],
        "readFirst": ["lib/models/video_project.dart"],
        "cautions": ["원격 데이터베이스 호출은 이 클래스에 없다."],
        "depends": ["project"],
        "confidence": "verified",
    },
    {
        "id": "project",
        "name": "VideoProject",
        "file": "lib/models/video_project.dart",
        "layer": "model",
        "role": "편집 중인 영상 하나의 전체 상태. 구간, 자막, 음악, 회전, 프리셋을 담는다.",
        "summary": "에디터가 읽고 쓰는 루트 모델이다.",
        "does": ["segments", "overlays", "musicTracks", "toJson()"],
        "why": ["화면과 내보내기가 같은 프로젝트 객체를 공유한다."],
        "talks": ["ClipSegment", "TextOverlay", "ProjectMusic", "EditorScreen", "ExportService"],
        "readFirst": ["lib/models/clip_segment.dart"],
        "cautions": [],
        "depends": ["segment", "overlay", "music"],
        "confidence": "verified",
    },
    {
        "id": "segment",
        "name": "ClipSegment",
        "file": "lib/models/clip_segment.dart",
        "layer": "model",
        "role": "원본 시간 위의 한 구간. 끝 전환(AppliedTransition)을 가질 수 있다.",
        "summary": "타임라인 조각과 그 조각 끝의 전환을 나타낸다.",
        "does": ["start / end", "transition", "volume", "audioEnvelope"],
        "why": ["자르기와 전환이 같은 모델에 있다. 별도 Transition 엔티티 테이블은 없다."],
        "talks": ["AppliedTransition", "PreviewFadeWindow", "encodeCompositionSegments"],
        "readFirst": ["lib/models/applied_transition.dart", "lib/utils/clip_segment_ops.dart"],
        "cautions": [],
        "depends": ["applied"],
        "confidence": "verified",
    },
    {
        "id": "applied",
        "name": "AppliedTransition",
        "file": "lib/models/applied_transition.dart",
        "layer": "model",
        "role": "구간에 붙은 전환의 id, 버전, 길이, 파라미터.",
        "summary": "사용자가 고른 전환의 저장 형태다.",
        "does": ["id", "duration", "parameters", "isNone"],
        "why": ["카탈로그 정의(TransitionItem)와 프로젝트에 저장된 적용 값을 분리한다."],
        "talks": ["TransitionEngine", "TransitionItem"],
        "readFirst": ["lib/services/transition_engine.dart"],
        "cautions": [],
        "depends": ["engine"],
        "confidence": "verified",
    },
    {
        "id": "editor",
        "name": "EditorScreen",
        "file": "lib/screens/editor_screen.dart",
        "layer": "screen",
        "role": "미리보기, 타임라인, 전환, 자막, 음악, 저장 진입을 한 화면에서 조율한다.",
        "summary": "편집 세션의 중심 State다. 별도 ViewModel 클래스는 없다.",
        "does": [
            "_initVideo()",
            "_attachTimelineCompositor()",
            "_togglePlay()",
            "_previewTransitionAtCut()",
            "_persistProject()",
            "_presentExport()",
        ],
        "why": [
            "재생 시계, 네이티브 텍스처, video_player 폴백, 스튜디오 도크가 한 State에 모여 있다.",
            "파일이 매우 길다. 기능별로 나누기 전에 이 화면이 허브라는 점을 먼저 아는 것이 맞다.",
        ],
        "talks": [
            "NativeVideoEngine",
            "TimelineWidget",
            "VideoPreviewWithOverlays",
            "ProjectStorageService",
            "ExportShareScreen",
        ],
        "readFirst": [
            "lib/services/native_video_engine.dart",
            "lib/services/composition_segments.dart",
        ],
        "cautions": [
            "네이티브 타임라인이 떠 있으면 재생은 NativeVideoEngine이 맡고, video_player는 폴백이다.",
            "prepareTransition()은 이 화면에서 호출하지 않는다. 짧은 GLES 세션은 현재 편집 재생 경로가 아니다.",
        ],
        "depends": ["engine", "timeline-ui", "preview-ui", "storage", "export-screen", "history"],
        "confidence": "verified",
    },
    {
        "id": "timeline-ui",
        "name": "TimelineWidget",
        "file": "lib/widgets/timeline_widget.dart",
        "layer": "widget",
        "role": "구간, 전환 마커, 자막, 음악 레인을 그리고 드래그 편집을 받는다.",
        "summary": "에디터 하단 타임라인 UI다.",
        "does": ["줌", "스크럽", "구간 트림 드래그", "전환 마커"],
        "why": ["시간 계산은 clip_segment_ops에 두고, 이 위젯은 입력과 그리기를 담당한다."],
        "talks": ["EditorScreen", "ClipSegment"],
        "readFirst": ["lib/utils/clip_segment_ops.dart"],
        "cautions": ["파일 분량이 크다. 페인터와 제스처가 같이 있다."],
        "depends": ["segment"],
        "confidence": "verified",
    },
    {
        "id": "preview-ui",
        "name": "VideoPreviewWithOverlays",
        "file": "lib/widgets/video_preview.dart",
        "layer": "widget",
        "role": "영상 위에 자막을 올리고 선택, 이동, 크기 조절을 받는다.",
        "summary": "미리보기 캔버스와 오버레이 제스처다.",
        "does": ["오버레이 hit test", "드래그", "회전된 클립 위 배치"],
        "why": ["영상 디코더와 자막 편집 제스처를 분리한다."],
        "talks": ["TextOverlay", "EditorScreen"],
        "readFirst": ["lib/models/text_overlay.dart"],
        "cautions": [],
        "depends": ["overlay"],
        "confidence": "verified",
    },
    {
        "id": "dual-slot",
        "name": "StableDualSlotPreview",
        "file": "lib/widgets/transition_preview_compositor.dart",
        "layer": "widget",
        "role": "video_player 두 장을 겹쳐 전환을 그리는 Flutter 폴백 컴포지터.",
        "summary": "네이티브 타임라인이 없을 때 쓰는 화면 합성이다.",
        "does": ["두 VideoPlayer 슬롯", "TransitionLayerCompositor에 포즈 전달"],
        "why": ["데스크톱처럼 네이티브 엔진이 없는 곳에서 전환 미리보기를 유지한다."],
        "talks": ["TransitionLayerCompositor", "EditorScreen"],
        "readFirst": ["lib/widgets/transition_layer_runtime.dart"],
        "cautions": [
            "iOS/Android에서 네이티브 타임라인이 활성화되면 이 위젯은 미리보기의 주 경로가 아니다.",
            "_buildPreviewVideoChild가 isTimelineActive이면 NativeVideoEngine.buildPreview()를 그린다.",
        ],
        "depends": ["layer-runtime"],
        "confidence": "verified",
    },
    {
        "id": "layer-runtime",
        "name": "TransitionLayerCompositor",
        "file": "lib/widgets/transition_layer_runtime.dart",
        "layer": "widget",
        "role": "카탈로그 레이어(투명도, 이동, 와이프, 잔물결, 격자)를 Flutter 위젯으로 그린다.",
        "summary": "Flutter 쪽 전환 렌더러다.",
        "does": ["TransitionLayerPose", "와이프 클리퍼", "잔물결", "격자"],
        "why": ["네이티브 합성이 없을 때의 화면 표현이다. 저장 파일의 픽셀은 네이티브 엔진이 그린다."],
        "talks": ["TransitionEngine", "StableDualSlotPreview"],
        "readFirst": ["lib/services/transition_engine.dart"],
        "cautions": ["저장 결과와 1:1이라고 단정하지 말 것. 저장은 ExportFrameCompositor / TransitionBlendEffect 경로다."],
        "depends": ["engine"],
        "confidence": "verified",
    },
    {
        "id": "engine",
        "name": "TransitionEngine",
        "file": "lib/services/transition_engine.dart",
        "layer": "service",
        "role": "AppliedTransition을 카탈로그 정의로 풀어 TransitionRenderPlan을 만든다.",
        "summary": "저장된 전환 id를 그리기 계획으로 바꾼다.",
        "does": ["plan()", "planForId()", "effectNameFor()"],
        "why": ["위젯과 네이티브가 카탈로그 JSON을 각자 해석하지 않게 한다."],
        "talks": ["TransitionCatalogService", "TransitionItem", "encodeCompositionSegments"],
        "readFirst": ["lib/models/transition_item.dart"],
        "cautions": [],
        "depends": ["transition-catalog", "item"],
        "confidence": "verified",
    },
    {
        "id": "transition-catalog",
        "name": "TransitionCatalogService",
        "file": "lib/services/transition_catalog_service.dart",
        "layer": "service",
        "role": "번들 전환 카탈로그를 읽고, 가능하면 원격 카탈로그로 갱신한다.",
        "summary": "전환 목록의 출처다.",
        "does": ["ensureInitialized()", "ChangeNotifier 알림"],
        "why": ["효과 목록을 앱 코드에 하드코딩하지 않는다."],
        "talks": ["TransitionRepository", "TransitionEngine"],
        "readFirst": ["lib/services/transition_repository.dart"],
        "cautions": ["원격 갱신 실패가 테스트 중 HTTP 400으로 찍힌 적이 있다. 번들 카탈로그로 동작은 계속된다. 현재 서버 계약의 세부 오류 원인은 이 페이지에서 확인하지 않았다."],
        "depends": ["item"],
        "confidence": "partial",
    },
    {
        "id": "item",
        "name": "TransitionItem",
        "file": "lib/models/transition_item.dart",
        "layer": "model",
        "role": "카탈로그에 있는 전환 하나의 정의. 레이어, 이징, 역할 효과.",
        "summary": "전환이 어떤 모션으로 구성되는지의 설계도다.",
        "does": ["layers", "effectName", "roleEffect", "renderer"],
        "why": ["AppliedTransition은 id만 저장하고, 모션 정의는 여기에 있다."],
        "talks": ["TransitionLayer", "TransitionRoleEffect", "TransitionEngine"],
        "readFirst": ["lib/models/transition_role_effect.dart"],
        "cautions": [],
        "depends": [],
        "confidence": "verified",
    },
    {
        "id": "segments-encode",
        "name": "encodeCompositionSegments",
        "file": "lib/services/composition_segments.dart",
        "layer": "service",
        "role": "타임라인 미리보기와 앨범 저장이 함께 쓰는 전환 설명 맵을 만든다.",
        "summary": "플랫폼 엔진에 넘기는 공통 전환 계획이다.",
        "does": [
            "encodeCompositionSegments()",
            "compositionEffectName()",
            "compositionMotion()",
        ],
        "why": ["미리보기와 저장이 전환 이름, 길이, 레이어를 따로 계산하지 않게 한다."],
        "talks": ["NativeVideoEngine.prepareTimeline", "ExportService._buildNativeExportRequest"],
        "readFirst": ["lib/services/native_video_engine.dart", "lib/services/export_service.dart"],
        "cautions": ["맵을 받은 뒤 픽셀을 그리는 코드는 플랫폼마다 다르다."],
        "depends": ["engine", "segment"],
        "confidence": "verified",
    },
    {
        "id": "ops",
        "name": "clip_segment_ops",
        "file": "lib/utils/clip_segment_ops.dart",
        "layer": "util",
        "role": "구간 분할, 전환 길이 제한, 소스 시간과 내보내기 시간의 변환.",
        "summary": "타임라인 시계의 순수 함수 모음이다.",
        "does": [
            "clampedTransitionDuration()",
            "exportTimeToSourceTime()",
            "sourceTimeToExportTime()",
            "previewFadeAt()",
        ],
        "why": ["EditorScreen의 재생 위치와 네이티브의 packed 시간이 이 함수로 맞물린다."],
        "talks": ["EditorScreen", "PreviewFadeWindow"],
        "readFirst": ["lib/screens/editor_screen.dart의 _nativePackedToSource"],
        "cautions": ["시간 변환은 순수 함수다. 네이티브 플레이어가 그 시간을 어떻게 샘플링하는지는 플랫폼 엔진을 봐야 한다."],
        "depends": ["segment"],
        "confidence": "verified",
    },
    {
        "id": "native",
        "name": "NativeVideoEngine",
        "file": "lib/services/native_video_engine.dart",
        "layer": "bridge",
        "role": "Flutter와 플랫폼 채널 com.smart.aveditor/native_video_engine 사이의 브리지.",
        "summary": "타임라인 준비, 재생 제어, 프로브, 내보내기를 네이티브에 전달한다.",
        "does": [
            "prepareTimeline()",
            "play() / pause() / seek() / preroll()",
            "export()",
            "buildPreview()",
            "prepareTransition()은 정의만 있고 에디터는 호출하지 않음",
        ],
        "why": ["화면이 플랫폼 API를 직접 부르지 않게 한다."],
        "talks": ["MethodChannel", "iOS NativeVideoEnginePlugin", "Android NativeVideoEnginePlugin"],
        "readFirst": ["ios/Runner/NativeVideoEnginePlugin.swift", "android/.../NativeVideoEnginePlugin.kt"],
        "cautions": ["supports()는 짧은 세션 능력 판별이다. 모바일 타임라인 재생의 본 경로는 prepareTimeline()이다."],
        "depends": ["segments-encode", "ios-plugin", "android-plugin"],
        "confidence": "verified",
    },
    {
        "id": "ios-plugin",
        "name": "iOS NativeVideoEnginePlugin",
        "file": "ios/Runner/NativeVideoEnginePlugin.swift",
        "layer": "native",
        "role": "prepareTimeline, play, export 메서드 채널을 AVPlayer 세션에 연결한다.",
        "summary": "iOS 네이티브 브리지다.",
        "does": ["prepareTimeline", "play / pause / seek / preroll", "export"],
        "why": ["Flutter 텍스처로 합성된 프레임을 올린다."],
        "talks": ["makeTimelinePreviewItem", "ExportFrameCompositor"],
        "readFirst": ["ios/Runner/NativeVideoEngineMedia.swift"],
        "cautions": [],
        "depends": ["ios-compositor"],
        "confidence": "verified",
    },
    {
        "id": "ios-compositor",
        "name": "ExportFrameCompositor",
        "file": "ios/Runner/NativeVideoEngineMedia.swift",
        "layer": "native",
        "role": "타임라인 미리보기와 앨범 저장이 공유하는 AVVideoCompositing 구현.",
        "summary": "iOS에서 전환 프레임을 실제로 그리는 클래스다.",
        "does": [
            "makeTimelinePreviewItem()",
            "buildCustomExportInstructions()",
            "ExportFrameCompositor.startRequest()",
            "compose() → doorway / puzzle / wipe / layers / composeNamed",
        ],
        "why": ["미리보기 AVPlayerItem과 저장 AVAssetExportSession이 같은 지시와 같은 컴포지터를 쓴다."],
        "talks": ["encodeCompositionSegments의 맵", "Core Image"],
        "readFirst": ["lib/services/composition_segments.dart"],
        "cautions": ["미리보기 긴 변은 약 720으로 맞추고, 저장은 요청한 해상도다. 합성 로직은 같고 출력 크기는 다르다."],
        "depends": ["segments-encode"],
        "confidence": "verified",
    },
    {
        "id": "android-plugin",
        "name": "Android NativeVideoEnginePlugin",
        "file": "android/app/src/main/kotlin/com/smart/aveditor/nativevideo/NativeVideoEnginePlugin.kt",
        "layer": "native",
        "role": "같은 메서드 채널을 Android 타임라인 세션과 내보내기에 연결한다.",
        "summary": "Android 네이티브 브리지다.",
        "does": [
            "prepareTimeline → TimelineCompositionSession",
            "prepareTransition → TransitionEngineSession (에디터 미사용)",
            "export → NativeVideoEngineMedia.export",
        ],
        "why": ["Flutter는 플랫폼을 나누지 않고 같은 채널 이름을 호출한다."],
        "talks": ["TimelineCompositionSession", "NativeVideoEngineMedia"],
        "readFirst": ["NativeVideoEngineMedia.kt", "TransitionBlendEffect.kt"],
        "cautions": ["TransitionEngineSession은 GLES 슬라이드 세션으로 파일에 남아 있다. 현재 에디터 재생은 이 세션을 시작하지 않는다."],
        "depends": ["android-player", "android-media"],
        "confidence": "verified",
    },
    {
        "id": "android-player",
        "name": "TimelineCompositionSession",
        "file": "android/app/src/main/kotlin/com/smart/aveditor/nativevideo/NativeVideoEnginePlugin.kt",
        "layer": "native",
        "role": "저장과 같은 Media3 Composition을 CompositionPlayer로 재생해 Flutter 텍스처에 그린다.",
        "summary": "Android 타임라인 미리보기 플레이어다.",
        "does": ["start()", "play()", "seekToMs()", "prerollToMs()"],
        "why": ["미리보기가 저장 컴포지션 객체를 재생하게 한다."],
        "talks": ["NativeVideoEngineMedia.buildTimelinePreview", "CompositionPlayer"],
        "readFirst": ["NativeVideoEngineMedia.buildExportComposition"],
        "cautions": ["에뮬레이터에서의 프레임 출력은 이 생성 작업에서 다시 실행해 확인하지 않았다. 호출 연결은 소스에서 확인했다."],
        "depends": ["android-media"],
        "confidence": "partial",
    },
    {
        "id": "android-media",
        "name": "NativeVideoEngineMedia",
        "file": "android/app/src/main/kotlin/com/smart/aveditor/nativevideo/NativeVideoEngineMedia.kt",
        "layer": "native",
        "role": "프로브, 파형, 그리고 미리보기와 저장이 공유하는 Composition 빌더.",
        "summary": "Android 내보내기/미리보기 컴포지션을 조립한다.",
        "does": [
            "buildTimelinePreview()",
            "export()",
            "buildExportComposition()",
            "TransitionCompositor",
            "packSegments()",
        ],
        "why": ["미리보기와 저장이 서로 다른 세그먼트 패킹을 만들지 않게 한다."],
        "talks": ["TransitionBlendEffect", "Transformer", "CompositionPlayer"],
        "readFirst": ["TransitionBlendEffect.kt"],
        "cautions": ["전환 구간에서 두 영상을 좌우로 패킹한 뒤 셰이더가 한 프레임으로 합친다. 패킹 좌표가 기기에서 어긋나는지는 런타임 확인이 필요하다."],
        "depends": ["android-blend"],
        "confidence": "partial",
    },
    {
        "id": "android-blend",
        "name": "TransitionBlendEffect",
        "file": "android/app/src/main/kotlin/com/smart/aveditor/nativevideo/TransitionBlendEffect.kt",
        "layer": "native",
        "role": "iOS compose()와 같은 순서로 와이프, 블러, 잔물결, 모자이크, 문, 퍼즐, 슬라이드, 페이드를 GL로 그린다.",
        "summary": "Android 전환 픽셀 패스다. 미리보기 Composition과 저장 Composition에 함께 붙는다.",
        "does": ["resolveBlend()", "TransitionBlendProgram.drawFrame()"],
        "why": ["Media3 OverlaySettings만으로는 와이프와 잔물결 같은 픽셀 마스크를 표현할 수 없다."],
        "talks": ["BlendWindow", "evaluateMotionPoses()"],
        "readFirst": ["ios ExportFrameCompositor.compose"],
        "cautions": ["셰이더 분기는 iOS 순서를 따라 작성했다. 모든 카탈로그 항목의 화면 일치는 기기에서 아직 대조하지 않았다."],
        "depends": ["android-media"],
        "confidence": "partial",
    },
    {
        "id": "export",
        "name": "ExportService",
        "file": "lib/services/export_service.dart",
        "layer": "service",
        "role": "프로젝트, 자막 래스터, 음원을 네이티브 export 요청으로 만들고 결과 파일을 돌려준다.",
        "summary": "앨범에 넣기 전 인코딩을 담당한다.",
        "does": [
            "exportToFile()",
            "_buildNativeExportRequest()",
            "encodeCompositionSegments() 사용",
            "NativeVideoEngine.export()",
        ],
        "why": ["화면은 인코더를 모르고, 이 서비스가 요청 맵을 만든다."],
        "talks": ["OverlayRasterService", "NativeVideoEngine", "VideoProject"],
        "readFirst": ["lib/services/composition_segments.dart"],
        "cautions": ["stream copy는 구간이 하나이고 전환, 자막, 음악, 회전이 없을 때만 canStreamCopy()가 허용한다."],
        "depends": ["native", "segments-encode", "raster", "project"],
        "confidence": "verified",
    },
    {
        "id": "raster",
        "name": "OverlayRasterService",
        "file": "lib/services/overlay_raster_service.dart",
        "layer": "service",
        "role": "자막을 내보내기용 비트맵 또는 프레임 시퀀스로 굽는다.",
        "summary": "텍스트 오버레이를 네이티브가 붙일 이미지로 만든다.",
        "does": ["renderAll()", "OverlayRaster"],
        "why": ["네이티브 컴포지터는 Flutter 텍스트 위젯을 직접 그리지 않는다."],
        "talks": ["TextOverlay", "ExportService"],
        "readFirst": ["lib/models/text_overlay.dart"],
        "cautions": [],
        "depends": ["overlay"],
        "confidence": "verified",
    },
    {
        "id": "overlay",
        "name": "TextOverlay",
        "file": "lib/models/text_overlay.dart",
        "layer": "model",
        "role": "프로젝트에 저장된 자막 하나의 문장, 시간, 스타일, 애니메이션.",
        "summary": "자막 모델이다.",
        "does": ["text", "start / end", "style", "animation"],
        "why": ["미리보기 제스처와 내보내기 래스터가 같은 모델을 읽는다."],
        "talks": ["VideoPreviewWithOverlays", "OverlayRasterService"],
        "readFirst": ["lib/widgets/video_preview.dart"],
        "cautions": [],
        "depends": [],
        "confidence": "verified",
    },
    {
        "id": "music",
        "name": "ProjectMusic",
        "file": "lib/models/project_music.dart",
        "layer": "model",
        "role": "타임라인에 올라간 음악 클립의 시작, 길이, 볼륨, 페이드.",
        "summary": "프로젝트에 붙은 음악이다.",
        "does": ["timelineStart", "clipDuration", "volume", "fade"],
        "why": ["음악 파일 자체는 프로젝트 폴더에 있고, 이 모델은 배치만 저장한다."],
        "talks": ["MusicPickerScreen", "EditorScreen", "ExportService"],
        "readFirst": ["lib/screens/music_picker_screen.dart"],
        "cautions": ["미리보기 음악 재생은 EditorScreen의 AudioPlayer 경로다. 네이티브 타임라인 컴포지션은 미리보기에서 음악 트랙을 비운다. 저장 요청에는 music이 들어간다."],
        "depends": [],
        "confidence": "verified",
    },
    {
        "id": "export-screen",
        "name": "ExportShareScreen",
        "file": "lib/screens/export_share_screen.dart",
        "layer": "screen",
        "role": "인코딩을 실행하고, 결과 미리보기와 공유 대상을 보여 준다.",
        "summary": "저장과 공유 화면이다.",
        "does": [
            "_run() → ExportService.exportToFile()",
            "_saveToAlbumIfNeeded() → ExportSaveService.saveExportedVideo()",
            "YouTubeUploadScreen으로 이동",
        ],
        "why": ["인코딩과 앨범 저장을 나눈다. 앨범 기록은 공유할 때 한다."],
        "talks": ["ExportService", "ExportSaveService", "ExportShareService", "ShareCatalogService"],
        "readFirst": ["lib/services/export_save_service.dart"],
        "cautions": ["내보내기 버튼을 누른다고 바로 사진 앨범에 복사되지는 않는다."],
        "depends": ["export", "save", "share", "yt-upload"],
        "confidence": "verified",
    },
    {
        "id": "save",
        "name": "ExportSaveService",
        "file": "lib/services/export_save_service.dart",
        "layer": "service",
        "role": "인코딩된 mp4를 사진 앨범 또는 macOS 저장 위치로 보낸다.",
        "summary": "파일 쓰기가 끝난 뒤의 앨범 저장이다.",
        "does": ["saveExportedVideo()", "_saveToGallery()", "_saveOnMacOS()"],
        "why": ["인코더와 사진 라이브러리 권한을 분리한다."],
        "talks": ["ExportShareScreen"],
        "readFirst": ["lib/screens/export_share_screen.dart"],
        "cautions": [],
        "depends": [],
        "confidence": "verified",
    },
    {
        "id": "share",
        "name": "ExportShareService",
        "file": "lib/services/export_share_service.dart",
        "layer": "service",
        "role": "시스템 공유 시트와 다른 앱 스킴을 연다.",
        "summary": "공유 실행기다.",
        "does": ["shareFile()", "openApp()", "appUri()"],
        "why": ["공유 UI와 플랫폼 공유 API를 화면에서 분리한다."],
        "talks": ["ShareCatalogService", "ExportShareScreen"],
        "readFirst": ["lib/services/share_catalog_service.dart"],
        "cautions": [],
        "depends": [],
        "confidence": "verified",
    },
    {
        "id": "yt-auth",
        "name": "YouTubeAuthService",
        "file": "lib/services/youtube_auth_service.dart",
        "layer": "service",
        "role": "YouTube 업로드에 쓰는 Google 로그인 상태.",
        "summary": "앱 전체 계정이 아니라 YouTube 연결이다.",
        "does": ["signIn()", "signOut()", "isSignedIn"],
        "why": ["홈 화면의 연결 토글과 업로드 화면이 같은 상태를 본다."],
        "talks": ["HomeScreen", "YouTubeUploadService"],
        "readFirst": ["lib/services/youtube_upload_service.dart"],
        "cautions": ["결제, 앱 회원 로그인은 이 저장소의 lib에서 찾지 못했다."],
        "depends": [],
        "confidence": "verified",
    },
    {
        "id": "yt-upload",
        "name": "YouTubeUploadService",
        "file": "lib/services/youtube_upload_service.dart",
        "layer": "service",
        "role": "인코딩된 파일을 YouTube Data API로 업로드한다.",
        "summary": "YouTube 업로드 클라이언트다.",
        "does": ["업로드 요청", "YouTubePlaylist"],
        "why": ["ExportShareScreen은 업로드 화면만 열고, HTTP는 이 서비스가 담당한다."],
        "talks": ["YouTubeUploadScreen", "YouTubeAuthService"],
        "readFirst": ["lib/screens/youtube_upload_screen.dart"],
        "cautions": ["엔드포인트 URL과 재시도 정책의 현재 값은 이 생성기가 전문을 다시 인용하지 않았다. 클래스는 파일에 있다."],
        "depends": ["yt-auth"],
        "confidence": "partial",
    },
    {
        "id": "history",
        "name": "EditorHistory",
        "file": "lib/services/editor_history.dart",
        "layer": "service",
        "role": "VideoProject 스냅샷으로 실행 취소와 다시 실행을 한다.",
        "summary": "편집 히스토리다.",
        "does": ["EditorSnapshot", "undo", "redo"],
        "why": ["프로젝트 모델 전체를 스냅샷한다. 명령 객체 패턴은 아니다."],
        "talks": ["EditorScreen", "VideoProject"],
        "readFirst": ["lib/screens/editor_screen.dart의 _mutate"],
        "cautions": ["undo 스택이 명령 단위인지 스냅샷 단위인지는 EditorSnapshot 구현을 보면 된다. 이 페이지는 스냅샷 클래스가 있다는 것까지 확인했다."],
        "depends": ["project"],
        "confidence": "partial",
    },
    {
        "id": "text-packs",
        "name": "TextTemplatePackService",
        "file": "lib/services/text_template_pack_service.dart",
        "layer": "service",
        "role": "자막 템플릿 팩 카탈로그를 불러온다.",
        "summary": "텍스트 스튜디오의 템플릿 출처다.",
        "does": ["ensureInitialized()"],
        "why": ["main()이 편집 화면을 열기 전에 데운다."],
        "talks": ["TextStudioPanel", "AveditorApp"],
        "readFirst": ["lib/widgets/text_studio_panel.dart"],
        "cautions": [],
        "depends": [],
        "confidence": "verified",
    },
    {
        "id": "settings",
        "name": "SettingsScreen",
        "file": "lib/screens/settings_screen.dart",
        "layer": "screen",
        "role": "내보내기 화질 같은 앱 설정을 보여 준다.",
        "summary": "설정 화면이다.",
        "does": ["화질 선택", "AppSettingsService"],
        "why": ["ExportShareScreen이 여기서 저장한 화질 프로필을 읽는다."],
        "talks": ["AppSettingsService", "ExportQualityProfile"],
        "readFirst": ["lib/services/app_settings_service.dart"],
        "cautions": [],
        "depends": [],
        "confidence": "verified",
    },
]

LAYERS = [
    ("app", "앱 진입", "라우터 프레임워크 없이 main이 HomeScreen을 연다."),
    ("screen", "화면", "State가 서비스를 직접 호출한다. ViewModel 클래스는 없다."),
    ("widget", "편집 위젯", "타임라인, 미리보기, Flutter 전환 폴백."),
    ("service", "서비스 / 순수 계획", "가져오기, 저장, 전환 계획, 인코딩 요청."),
    ("model", "모델", "프로젝트와 카탈로그 정의."),
    ("bridge", "Flutter 브리지", "양쪽 플랫폼이 같은 메서드 채널을 쓴다."),
    ("native", "네이티브 엔진", "iOS AVVideoCompositing, Android Media3 + GL."),
    ("util", "시간 계산", "소스 시간과 내보내기 시간의 변환."),
]

# Sequence messages use participant ids. kind: call | async | return | self | note.
# fragments draw UML alt boxes over inclusive message indexes.
FLOWS = [
    {
        "id": "load",
        "title": "영상 로딩",
        "summary": "프로젝트를 읽고 video_player를 만든 뒤, 모바일이면 같은 세그먼트 계획으로 네이티브 타임라인을 붙인다.",
        "participants": [
            {"id": "user", "name": "User"},
            {"id": "editor", "name": "EditorScreen"},
            {"id": "storage", "name": "ProjectStorage"},
            {"id": "player", "name": "VideoPlayer"},
            {"id": "bridge", "name": "NativeVideoEngine"},
            {"id": "ios", "name": "iOS Plugin"},
            {"id": "android", "name": "Android Plugin"},
        ],
        "messages": [
            {"from": "user", "to": "editor", "kind": "call", "label": "프로젝트 열기", "node": "editor"},
            {"from": "editor", "to": "storage", "kind": "async", "label": "_initVideo → load(projectId)", "node": "storage"},
            {"from": "storage", "to": "editor", "kind": "return", "label": "VideoProject", "node": "project"},
            {"from": "editor", "to": "player", "kind": "async", "label": "VideoPlayerController.file.initialize", "node": "editor"},
            {"from": "editor", "to": "editor", "kind": "self", "label": "normalizeSegments / segmentsFromTrim", "node": "editor"},
            {"from": "editor", "to": "editor", "kind": "self", "label": "unawaited(_attachTimelineCompositor)", "node": "editor"},
            {"from": "editor", "to": "bridge", "kind": "async", "label": "prepareTimeline(sourcePath, segments)", "node": "native"},
            {"from": "bridge", "to": "bridge", "kind": "self", "label": "encodeCompositionSegments", "node": "segments-encode"},
            {"from": "bridge", "to": "ios", "kind": "async", "label": "prepareTimeline", "node": "ios-plugin"},
            {"from": "ios", "to": "ios", "kind": "self", "label": "makeTimelinePreviewItem", "node": "ios-compositor"},
            {"from": "ios", "to": "ios", "kind": "self", "label": "AVPlayerItem.videoComposition = ExportFrameCompositor", "node": "ios-compositor"},
            {"from": "ios", "to": "bridge", "kind": "return", "label": "textureId, durationMs", "node": "ios-plugin"},
            {"from": "bridge", "to": "android", "kind": "async", "label": "prepareTimeline", "node": "android-plugin"},
            {"from": "android", "to": "android", "kind": "self", "label": "buildTimelinePreview  overlays=[] music=[]", "node": "android-media"},
            {"from": "android", "to": "android", "kind": "self", "label": "TimelineCompositionSession.start", "node": "android-player"},
            {"from": "android", "to": "android", "kind": "self", "label": "Composition + TransitionBlendEffect", "node": "android-blend"},
            {"from": "android", "to": "bridge", "kind": "return", "label": "textureId, durationMs", "node": "android-plugin"},
            {"from": "bridge", "to": "editor", "kind": "async", "label": "positionStream (EventChannel)", "node": "native"},
            {"from": "editor", "to": "editor", "kind": "self", "label": "_nativePackedToSource → exportTimeToSourceTime", "node": "ops"},
            {"from": "editor", "to": "player", "kind": "note", "label": "id가 null이거나 모바일이 아니면 video_player가 미리보기를 유지", "node": "editor"},
        ],
        "fragments": [
            {"label": "alt", "start": 8, "end": 16, "sections": [
                {"at": 8, "guard": "[iOS]"},
                {"at": 12, "guard": "[Android]"},
            ]},
        ],
    },
    {
        "id": "text",
        "title": "텍스트 추가",
        "summary": "자막은 VideoProject.overlays에 들어가고 미리보기는 Flutter 위젯이 그린다. 이 경로에는 iOS/Android 분기가 없다.",
        "participants": [
            {"id": "user", "name": "User"},
            {"id": "editor", "name": "EditorScreen"},
            {"id": "history", "name": "EditorHistory"},
            {"id": "project", "name": "VideoProject"},
            {"id": "studio", "name": "TextStudioPanel"},
            {"id": "preview", "name": "VideoPreview"},
            {"id": "storage", "name": "ProjectStorage"},
        ],
        "messages": [
            {"from": "user", "to": "editor", "kind": "call", "label": "텍스트 버튼", "node": "editor"},
            {"from": "editor", "to": "editor", "kind": "self", "label": "_addTextOverlay → _placeNewTextOverlay", "node": "editor"},
            {"from": "editor", "to": "editor", "kind": "self", "label": "_textPlacementSourceTime", "node": "editor"},
            {"from": "editor", "to": "editor", "kind": "self", "label": "TextOverlay(text:'', +3s) fitOverlayBoxToText", "node": "overlay"},
            {"from": "editor", "to": "history", "kind": "call", "label": "_mutate → record(EditorSnapshot)", "node": "history"},
            {"from": "editor", "to": "project", "kind": "call", "label": "assignOverlayLane + overlays.add", "node": "project"},
            {"from": "editor", "to": "studio", "kind": "call", "label": "_presentStudioDock → TextStudioPanel", "node": "editor"},
            {"from": "user", "to": "studio", "kind": "call", "label": "문장·스타일 입력", "node": "editor"},
            {"from": "studio", "to": "editor", "kind": "call", "label": "onChanged → _updateOverlay", "node": "editor"},
            {"from": "editor", "to": "project", "kind": "call", "label": "overlays[index] = fitOverlayBoxToText", "node": "overlay"},
            {"from": "editor", "to": "preview", "kind": "call", "label": "VideoPreviewWithOverlays가 자막을 그림", "node": "preview-ui"},
            {"from": "editor", "to": "storage", "kind": "async", "label": "_scheduleSave 500ms → save", "node": "storage"},
            {"from": "editor", "to": "preview", "kind": "note", "label": "네이티브 타임라인 요청에는 overlays를 넣지 않는다", "node": "android-media"},
            {"from": "user", "to": "studio", "kind": "call", "label": "확인 _closeTextStudio", "node": "editor"},
            {"from": "editor", "to": "project", "kind": "call", "label": "빈 문장이면 _deleteOverlay", "node": "project"},
            {"from": "editor", "to": "project", "kind": "call", "label": "문장이 있으면 trim 후 오버레이 유지", "node": "overlay"},
        ],
        "fragments": [
            {"label": "alt", "start": 14, "end": 15, "sections": [
                {"at": 14, "guard": "[text가 비어 있음]"},
                {"at": 15, "guard": "[text가 있음]"},
            ]},
        ],
    },
    {
        "id": "transition",
        "title": "전환 적용과 미리보기",
        "summary": "AppliedTransition을 구간에 저장한 뒤 컷 구간을 재생한다. 모바일은 네이티브 타임라인, 그 외에는 video_player 두 장이다.",
        "participants": [
            {"id": "user", "name": "User"},
            {"id": "picker", "name": "TransitionPicker"},
            {"id": "editor", "name": "EditorScreen"},
            {"id": "engine", "name": "TransitionEngine"},
            {"id": "project", "name": "VideoProject"},
            {"id": "bridge", "name": "NativeVideoEngine"},
            {"id": "ios", "name": "iOS Compositor"},
            {"id": "android", "name": "Android Blend"},
            {"id": "player", "name": "VideoPlayer 폴백"},
        ],
        "messages": [
            {"from": "user", "to": "picker", "kind": "call", "label": "전환 타일", "node": "engine"},
            {"from": "picker", "to": "editor", "kind": "call", "label": "onApplied → _applyTransitionAtCut", "node": "editor"},
            {"from": "editor", "to": "engine", "kind": "call", "label": "clampedTransitionDuration", "node": "ops"},
            {"from": "editor", "to": "project", "kind": "call", "label": "_mutate → ClipSegment.transition", "node": "applied"},
            {"from": "editor", "to": "editor", "kind": "self", "label": "_previewTransitionAtCut", "node": "editor"},
            {"from": "editor", "to": "editor", "kind": "self", "label": "창 [cut−⌊td/2⌋, cut+⌈td/2⌉)", "node": "ops"},
            {"from": "editor", "to": "bridge", "kind": "async", "label": "_attachTimelineCompositor(seekTo:)", "node": "native"},
            {"from": "bridge", "to": "bridge", "kind": "self", "label": "encodeCompositionSegments", "node": "segments-encode"},
            {"from": "bridge", "to": "ios", "kind": "async", "label": "채널 prepareTimeline", "node": "ios-plugin"},
            {"from": "ios", "to": "ios", "kind": "self", "label": "makeTimelinePreviewItem", "node": "ios-compositor"},
            {"from": "ios", "to": "ios", "kind": "self", "label": "ExportFrameCompositor.compose", "node": "ios-compositor"},
            {"from": "bridge", "to": "android", "kind": "async", "label": "채널 prepareTimeline", "node": "android-plugin"},
            {"from": "android", "to": "android", "kind": "self", "label": "buildTimelinePreview", "node": "android-media"},
            {"from": "android", "to": "android", "kind": "self", "label": "TransitionCompositor.packHalf", "node": "android-media"},
            {"from": "android", "to": "android", "kind": "self", "label": "TransitionBlendEffect.resolveBlend", "node": "android-blend"},
            {"from": "editor", "to": "bridge", "kind": "async", "label": "isTimelineActive면 play()", "node": "native"},
            {"from": "editor", "to": "editor", "kind": "self", "label": "_armTransitionPreviewStop. 벽시계 없음", "node": "editor"},
            {"from": "bridge", "to": "editor", "kind": "async", "label": "positionStream이 미리보기 종료를 결정", "node": "editor"},
            {"from": "editor", "to": "player", "kind": "async", "label": "_ensureAuxController seekTo(incoming.start)", "node": "dual-slot"},
            {"from": "editor", "to": "player", "kind": "async", "label": "controller.seekTo + play", "node": "editor"},
            {"from": "player", "to": "player", "kind": "self", "label": "StableDualSlotPreview + TransitionLayerCompositor", "node": "layer-runtime"},
            {"from": "editor", "to": "editor", "kind": "self", "label": "_armTransitionPreviewStop(wallClockFallback)", "node": "editor"},
        ],
        "fragments": [
            {"label": "alt", "start": 8, "end": 13, "sections": [
                {"at": 8, "guard": "[iOS 구현]"},
                {"at": 11, "guard": "[Android 구현]"},
            ]},
            {"label": "alt", "start": 14, "end": 20, "sections": [
                {"at": 14, "guard": "[textureId가 있어 isTimelineActive]"},
                {"at": 17, "guard": "[else 데스크톱이거나 prepareTimeline 실패]"},
            ]},
        ],
    },
    {
        "id": "timeline-play",
        "title": "타임라인 재생",
        "summary": "재생 버튼은 인코더를 부르지 않는다. 이미 붙은 타임라인 컴포지션을 플레이어가 재생하고, Flutter는 그 프레임을 Texture로 보여 준다.",
        "participants": [
            {"id": "user", "name": "User"},
            {"id": "editor", "name": "EditorScreen"},
            {"id": "bridge", "name": "NativeVideoEngine"},
            {"id": "ios", "name": "iOS Session"},
            {"id": "android", "name": "TimelineCompositionSession"},
            {"id": "preview", "name": "Flutter Texture"},
            {"id": "audio", "name": "AudioPlayer"},
            {"id": "player", "name": "VideoPlayer 폴백"},
        ],
        "messages": [
            {"from": "user", "to": "editor", "kind": "call", "label": "재생 버튼 또는 미리보기 탭", "node": "editor"},
            {"from": "editor", "to": "editor", "kind": "self", "label": "_togglePlay. 전환 미리보기 타이머는 취소", "node": "editor"},
            {"from": "editor", "to": "editor", "kind": "self", "label": "isInKeptRegion이면 _playhead, 아니면 구간 start", "node": "ops"},
            {"from": "editor", "to": "bridge", "kind": "async", "label": "play()", "node": "native"},
            {"from": "editor", "to": "bridge", "kind": "async", "label": "seek(_sourceToNativePacked(start), resume: true)", "node": "native"},
            {"from": "bridge", "to": "ios", "kind": "async", "label": "play / seek", "node": "ios-plugin"},
            {"from": "ios", "to": "ios", "kind": "self", "label": "NativeVideoEngineSession → AVPlayer.play", "node": "ios-plugin"},
            {"from": "ios", "to": "ios", "kind": "self", "label": "이미 붙은 ExportFrameCompositor가 프레임을 그림", "node": "ios-compositor"},
            {"from": "bridge", "to": "android", "kind": "async", "label": "timeline.play / seekToMs", "node": "android-player"},
            {"from": "android", "to": "android", "kind": "self", "label": "CompositionPlayer.play. Transformer는 호출하지 않음", "node": "android-player"},
            {"from": "android", "to": "android", "kind": "self", "label": "같은 Composition의 TransitionBlendEffect가 프레임을 그림", "node": "android-blend"},
            {"from": "ios", "to": "bridge", "kind": "async", "label": "EventChannel position", "node": "native"},
            {"from": "android", "to": "bridge", "kind": "async", "label": "33ms tick position", "node": "android-player"},
            {"from": "bridge", "to": "editor", "kind": "async", "label": "positionStream", "node": "native"},
            {"from": "editor", "to": "editor", "kind": "self", "label": "_nativePackedToSource → exportTimeToSourceTime", "node": "ops"},
            {"from": "editor", "to": "preview", "kind": "call", "label": "buildPreview() Texture. 자막은 Flutter 위젯", "node": "native"},
            {"from": "editor", "to": "audio", "kind": "async", "label": "_syncMusicPlayback. 네이티브 컴포지션 밖", "node": "editor"},
            {"from": "editor", "to": "player", "kind": "call", "label": "controller.play. 컷이면 _driveFadePreview", "node": "dual-slot"},
        ],
        "fragments": [
            {"label": "alt", "start": 3, "end": 16, "sections": [
                {"at": 3, "guard": "[isTimelineActive] 네이티브 타임라인 재생"},
                {"at": 5, "guard": "[iOS] AVPlayer + ExportFrameCompositor"},
                {"at": 8, "guard": "[Android] CompositionPlayer + TransitionBlendEffect"},
                {"at": 11, "guard": "[공통] 재생 위치와 Texture. 인코더는 호출하지 않음"},
            ]},
            {"label": "alt", "start": 17, "end": 17, "sections": [
                {"at": 17, "guard": "[else] video_player. CompositionPlayer도 인코더도 아님"},
            ]},
        ],
    },
    {
        "id": "export",
        "title": "저장 인코딩",
        "summary": "자막을 비트맵으로 구운 뒤 같은 전환 계획으로 네이티브가 mp4를 만든다. 앨범 복사는 이 시퀀스 다음이다.",
        "participants": [
            {"id": "user", "name": "User"},
            {"id": "editor", "name": "EditorScreen"},
            {"id": "share", "name": "ExportShareScreen"},
            {"id": "export", "name": "ExportService"},
            {"id": "raster", "name": "OverlayRaster"},
            {"id": "bridge", "name": "NativeVideoEngine"},
            {"id": "ios", "name": "iOS Export"},
            {"id": "android", "name": "Android Export"},
        ],
        "messages": [
            {"from": "user", "to": "editor", "kind": "call", "label": "보내기 버튼", "node": "editor"},
            {"from": "editor", "to": "share", "kind": "async", "label": "_presentExport → Navigator.push", "node": "export-screen"},
            {"from": "share", "to": "export", "kind": "async", "label": "_run → exportToFile", "node": "export"},
            {"from": "export", "to": "raster", "kind": "async", "label": "renderAll(visible overlays)", "node": "raster"},
            {"from": "raster", "to": "export", "kind": "return", "label": "OverlayRaster 이미지", "node": "raster"},
            {"from": "export", "to": "export", "kind": "self", "label": "_buildNativeExportRequest", "node": "export"},
            {"from": "export", "to": "export", "kind": "self", "label": "encodeCompositionSegments + overlays + music", "node": "segments-encode"},
            {"from": "export", "to": "bridge", "kind": "async", "label": "NativeVideoEngine.export", "node": "native"},
            {"from": "bridge", "to": "ios", "kind": "async", "label": "export", "node": "ios-plugin"},
            {"from": "ios", "to": "ios", "kind": "self", "label": "exportReencode + ExportFrameCompositor", "node": "ios-compositor"},
            {"from": "ios", "to": "ios", "kind": "self", "label": "오버레이는 컴포지터가 굽는다", "node": "ios-compositor"},
            {"from": "bridge", "to": "android", "kind": "async", "label": "export", "node": "android-plugin"},
            {"from": "android", "to": "android", "kind": "self", "label": "buildExportComposition(overlays, music)", "node": "android-media"},
            {"from": "android", "to": "android", "kind": "self", "label": "Transformer + TransitionBlendEffect + overlayEffect", "node": "android-blend"},
            {"from": "bridge", "to": "share", "kind": "return", "label": "mp4 path", "node": "export-screen"},
            {"from": "share", "to": "share", "kind": "note", "label": "앨범 기록은 공유 때 ExportSaveService.saveExportedVideo", "node": "save"},
        ],
        "fragments": [
            {"label": "alt", "start": 8, "end": 13, "sections": [
                {"at": 8, "guard": "[iOS] AVAssetExportSession"},
                {"at": 11, "guard": "[Android] Media3 Transformer"},
            ]},
        ],
    },
    {
        "id": "music",
        "title": "음악 추가",
        "summary": "미리보기 음악은 Flutter AudioPlayer다. 네이티브 타임라인 컴포지션에는 음악을 넣지 않고, 저장 요청에만 넣는다.",
        "participants": [
            {"id": "user", "name": "User"},
            {"id": "editor", "name": "EditorScreen"},
            {"id": "picker", "name": "MusicPickerScreen"},
            {"id": "project", "name": "VideoProject"},
            {"id": "audio", "name": "AudioPlayer"},
            {"id": "native", "name": "타임라인 컴포지션"},
            {"id": "export", "name": "ExportService"},
        ],
        "messages": [
            {"from": "user", "to": "editor", "kind": "call", "label": "음악 버튼", "node": "editor"},
            {"from": "editor", "to": "picker", "kind": "async", "label": "_openMusicPicker → MusicPickerScreen", "node": "music"},
            {"from": "picker", "to": "editor", "kind": "return", "label": "ProjectMusic", "node": "music"},
            {"from": "editor", "to": "project", "kind": "call", "label": "_mutate assignMusicLane + musicTracks.add", "node": "project"},
            {"from": "editor", "to": "audio", "kind": "async", "label": "_syncMusicPlayback", "node": "editor"},
            {"from": "editor", "to": "native", "kind": "note", "label": "prepareTimeline 인자에는 music이 없다", "node": "android-media"},
            {"from": "export", "to": "native", "kind": "call", "label": "저장 요청의 music만 네이티브 믹스에 들어간다", "node": "export"},
        ],
        "fragments": [],
    },
    {
        "id": "import",
        "title": "영상 가져오기",
        "summary": "갤러리·파일·카메라에서 고른 파일로 프로젝트를 만들고 에디터를 연다. 로딩 시퀀스는 그 다음이다.",
        "participants": [
            {"id": "user", "name": "User"},
            {"id": "home", "name": "HomeScreen"},
            {"id": "import", "name": "VideoImportService"},
            {"id": "storage", "name": "ProjectStorage"},
            {"id": "editor", "name": "EditorScreen"},
        ],
        "messages": [
            {"from": "user", "to": "home", "kind": "call", "label": "갤러리 / 파일 / 카메라", "node": "home"},
            {"from": "home", "to": "import", "kind": "async", "label": "pickFromGallery / pickFromFiles / pickFromCamera", "node": "import"},
            {"from": "import", "to": "home", "kind": "return", "label": "로컬 파일 경로", "node": "import"},
            {"from": "home", "to": "storage", "kind": "async", "label": "createFromImport(path)", "node": "storage"},
            {"from": "storage", "to": "home", "kind": "return", "label": "projectId", "node": "project"},
            {"from": "home", "to": "editor", "kind": "async", "label": "Navigator.push(EditorScreen)", "node": "editor"},
        ],
        "fragments": [],
    },
]

BRANCHES = {
    "channel": "com.smart.aveditor/native_video_engine",
    "events": "com.smart.aveditor/native_video_engine/events",
    "note": "Dart에 iOS/Android 구현을 나누는 abstract class는 없다. NativeVideoEngine 싱글턴이 메서드 채널 이름을 호출하고, 구현체는 각 플랫폼 플러그인이다.",
    "methods": [
        {
            "name": "prepareTimeline",
            "caller": "NativeVideoEngine.prepareTimeline",
            "editor": "EditorScreen._attachTimelineCompositorBody. isPlatformSupported가 아니면 return.",
            "ios": "NativeVideoEnginePlugin.handle → makeTimelinePreviewItem → NativeVideoEngineSession. 프레임은 ExportFrameCompositor.",
            "android": "NativeVideoEnginePlugin.onMethodCall → buildTimelinePreview → TimelineCompositionSession. 프레임은 TransitionCompositor + TransitionBlendEffect.",
        },
        {
            "name": "prepareTransition",
            "caller": "NativeVideoEngine.prepareTransition",
            "editor": "에디터는 이 메서드를 호출하지 않는다. 플러그인 구현만 남아 있다.",
            "ios": "짧은 NativeVideoEngineSession. 같은 ExportFrameCompositor.",
            "android": "TransitionEngineSession. GLES 슬라이드 세션. 타임라인 세션과 별개.",
        },
        {
            "name": "play / pause / seek / preroll",
            "caller": "NativeVideoEngine.play 등",
            "editor": "타임라인이 떠 있으면 EditorScreen._togglePlay이 네이티브 시계를 쓴다.",
            "ios": "NativeVideoEngineSession → AVPlayer.",
            "android": "timeline이 있으면 TimelineCompositionSession, 없으면 TransitionEngineSession.",
        },
        {
            "name": "export",
            "caller": "NativeVideoEngine.export",
            "editor": "ExportShareScreen._run → ExportService.exportToFile.",
            "ios": "NativeVideoEngineMedia.export → exportReencode. AVAssetExportSession.videoComposition이 ExportFrameCompositor.",
            "android": "NativeVideoEngineMedia.export → buildExportComposition → Transformer. 같은 TransitionBlendEffect.",
        },
        {
            "name": "probe / decodeWaveform",
            "caller": "NativeVideoEngine.probe, decodeWaveform",
            "editor": "길이·파형. 편집 시계와는 별도.",
            "ios": "NativeVideoEngineMedia.probe / decodeWaveform.",
            "android": "NativeVideoEngineMedia.probe / decodeWaveform.",
        },
    ],
    "splits": [
        {
            "title": "전환 미리보기",
            "shared": "양쪽이 성공하면 EditorScreen은 prepareTimeline 한 경로만 탄다. 효과 설명은 encodeCompositionSegments.",
            "ios": "ExportFrameCompositor.compose 순서: doorway, puzzle, ripple, cells, wipe, layers, composeNamed.",
            "android": "좌우 패킹 후 TransitionBlendEffect.resolveBlend가 같은 순서로 GL을 고른다.",
            "fallback": "isPlatformSupported가 거짓이거나 textureId가 null이면 _ensureAuxController와 video_player 두 장, TransitionLayerCompositor. 종료는 wallClockFallback Timer.",
        },
        {
            "title": "자막",
            "shared": "미리보기에는 플랫폼 분기가 없다. VideoPreviewWithOverlays가 TextOverlay를 Flutter로 그린다.",
            "ios": "타임라인 미리보기는 자막을 굽지 않는다. 저장 때 ExportFrameCompositor가 오버레이를 굽는다.",
            "android": "buildTimelinePreview는 overlays=emptyList(). 저장 때 overlayEffect가 굽는다.",
            "fallback": "비트맵은 저장 전에 OverlayRasterService.renderAll이 만든다. 플랫폼 공통.",
        },
        {
            "title": "음악",
            "shared": "모델은 ProjectMusic. 미리보기 재생은 EditorScreen의 AudioPlayer._syncMusicPlayback.",
            "ios": "makeTimelinePreviewItem 인자에는 프로젝트 음악 트랙이 없다. 원본 오디오 트랙만 있으면 붙인다.",
            "android": "buildTimelinePreview는 music=emptyList().",
            "fallback": "저장 요청에만 music이 들어간다. ExportService._buildNativeExportRequest.",
        },
        {
            "title": "영상 가져오기",
            "shared": "HomeScreen이 VideoImportService를 호출한다.",
            "ios": "VideoImportService의 갤러리 분기에 Platform.isIOS 처리가 있다.",
            "android": "갤러리 피커의 코덱 요청은 third_party/image_picker_android에 있다. 이 다이어그램의 앱 서비스 밖이다.",
            "fallback": "데스크톱은 파일 선택. PlatformHelper.supportsFilePicker.",
        },
    ],
}

DATA_FLOWS = [
    {
        "id": "edit-model",
        "title": "편집 상태",
        "steps": [
            {"name": "picked file path", "note": "VideoImportService가 돌려주는 문자열"},
            {"name": "VideoProject", "note": "ProjectStorageService JSON"},
            {"name": "ClipSegment", "note": "원본 시간 구간"},
            {"name": "AppliedTransition", "note": "id, duration, parameters"},
            {"name": "TransitionRenderPlan", "note": "TransitionEngine.plan"},
            {"name": "encodeCompositionSegments 맵", "note": "transitionEffect, transitionLayers, transitionKind"},
        ],
    },
    {
        "id": "export-model",
        "title": "저장 결과",
        "steps": [
            {"name": "VideoProject", "note": "ExportShareScreen이 받는 인자"},
            {"name": "OverlayRaster", "note": "자막 비트맵"},
            {"name": "native export request", "note": "ExportService._buildNativeExportRequest"},
            {"name": "mp4 path", "note": "NativeVideoEngine.export 반환"},
            {"name": "앨범 / 공유", "note": "ExportSaveService, ExportShareService. 인코딩과 별도"},
        ],
    },
]

READING = [
    {"file": "lib/main.dart", "why": "앱이 HomeScreen에서 시작하고, 카탈로그를 미리 읽는다는 것만 보면 된다."},
    {"file": "lib/screens/home_screen.dart", "why": "가져오기와 프로젝트 생성이 서비스를 어떻게 부르는지 가장 짧은 흐름이다."},
    {"file": "lib/services/video_import_service.dart", "why": "편집으로 넘어가기 전에 파일이 어디서 오는지 고정된다."},
    {"file": "lib/models/video_project.dart", "why": "이후 모든 화면이 이 객체 하나를 저장하고 고친다."},
    {"file": "lib/models/clip_segment.dart", "why": "구간과 전환이 한 모델이라는 점이 타임라인 이해의 시작이다."},
    {"file": "lib/services/transition_engine.dart", "why": "저장된 id가 카탈로그 모션으로 바뀌는 지점이다."},
    {"file": "lib/services/composition_segments.dart", "why": "미리보기와 저장이 공유하는 요청 형식이다. 플랫폼 코드를 보기 전에 여기를 본다."},
    {"file": "lib/services/native_video_engine.dart", "why": "Flutter가 네이티브에 무엇을 부탁하는지가 메서드 이름으로 보인다."},
    {"file": "lib/screens/editor_screen.dart", "why": "재생과 미리보기의 조율이 여기 있다. 길어서 함수 이름(_attachTimelineCompositor, _togglePlay, _presentExport)부터 찾는다."},
    {"file": "ios/Runner/NativeVideoEngineMedia.swift", "why": "iOS는 ExportFrameCompositor 한 곳이 미리보기와 저장 프레임을 그린다."},
    {"file": "android/app/src/main/kotlin/com/smart/aveditor/nativevideo/NativeVideoEngineMedia.kt", "why": "Android 미리보기와 저장이 같은 buildExportComposition을 쓴다."},
    {"file": "android/app/src/main/kotlin/com/smart/aveditor/nativevideo/TransitionBlendEffect.kt", "why": "Android에서 와이프·블러·잔물결·모자이크를 그리는 셰이더다."},
    {"file": "lib/services/export_service.dart", "why": "저장 요청이 공통 세그먼트 맵에 자막과 음악을 더하는 방식이다."},
    {"file": "lib/screens/export_share_screen.dart", "why": "인코딩과 앨범 저장이 분리되어 있다는 제품 규칙이 여기 있다."},
]

UNKNOWNS = [
    "Android CompositionPlayer가 전환 셰이더 프레임을 에뮬레이터 화면에 실제로 올리는지는 이 생성 과정에서 재실행하지 않았다. 연결 코드는 소스에 있다.",
    "TransitionBlendEffect의 좌우 패킹 좌표가 모든 해상도에서 iOS 프레임과 같은지는 기기 대조 전이다.",
    "YouTubeUploadService의 HTTP 재시도·할당량 처리 전문은 이 페이지가 줄 단위로 다시 인용하지 않았다.",
    "원격 전환 카탈로그 갱신이 HTTP 400을 내는 서버 측 원인은 확인하지 않았다. 앱은 번들 카탈로그로 계속 동작한다.",
    "결제, 앱 회원 로그인, 서버 데이터베이스 계층은 lib에서 찾지 못했다. 없는 것으로 표시하며 추측으로 노드를 만들지 않았다.",
    "prepareTransition / TransitionEngineSession은 플러그인에 남아 있지만 현재 에디터 코드는 호출하지 않는다.",
]


def used_by_map(nodes: list[dict]) -> dict[str, list[str]]:
    incoming: dict[str, list[str]] = {n["id"]: [] for n in nodes}
    for node in nodes:
        for dep in node["depends"]:
            incoming.setdefault(dep, []).append(node["id"])
    return incoming


def main() -> None:
    files = []
    for folder in SCAN_DIRS:
        if not folder.exists():
            continue
        for path in sorted(folder.rglob("*")):
            if path.is_file() and should_scan(path):
                files.append(scan_file(path))
    by_path = {item["path"]: item for item in files}
    incoming = used_by_map(NODES)
    nodes = []
    for node in NODES:
        scanned = by_path.get(node["file"], {})
        methods = []
        for line in node.get("does") or []:
            methods.extend(re.findall(r"([A-Za-z_][\w]*)\s*\(", line))
        for name in scanned.get("methods") or []:
            if name not in methods:
                methods.append(name)
        item = dict(node)
        item["methods"] = methods[:18]
        item["usedBy"] = incoming.get(node["id"], [])
        item["scannedClasses"] = scanned.get("classes") or []
        item["lines"] = scanned.get("lines")
        if node["file"] not in by_path:
            item["confidence"] = "missing"
            item["cautions"] = list(item["cautions"]) + [
                "생성 시점에 이 경로의 파일을 찾지 못했다."
            ]
        nodes.append(item)

    layers = []
    for layer_id, title, note in LAYERS:
        layers.append(
            {
                "id": layer_id,
                "title": title,
                "note": note,
                "nodeIds": [n["id"] for n in nodes if n["layer"] == layer_id],
            }
        )

    payload = {
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "project": "AVEditor client",
        "summary": (
            "Flutter 화면이 서비스를 직접 호출한다. ViewModel, UseCase, Repository 계층은 없다. "
            "타임라인 미리보기와 저장은 encodeCompositionSegments로 같은 전환 계획을 만들고, "
            "iOS는 ExportFrameCompositor, Android는 Media3 Composition과 TransitionBlendEffect가 그 계획을 그린다."
        ),
        "layers": layers,
        "nodes": nodes,
        "files": files,
        "tree": build_tree(files),
        "flows": [
            {
                **flow,
                "steps": [
                    {
                        "actor": next(p["name"] for p in flow["participants"] if p["id"] == msg["from"]),
                        "target": next(p["name"] for p in flow["participants"] if p["id"] == msg["to"]),
                        "fn": msg["label"],
                        "async": msg["kind"] in {"async", "return"},
                        "node": msg.get("node") or "",
                    }
                    for msg in flow["messages"]
                ],
            }
            for flow in FLOWS
        ],
        "branches": BRANCHES,
        "dataFlows": DATA_FLOWS,
        "reading": READING,
        "unknowns": UNKNOWNS,
        "fileCount": len(files),
    }
    DOCS.mkdir(parents=True, exist_ok=True)
    (DOCS / "architecture.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    template = TEMPLATE.read_text(encoding="utf-8")
    html = template.replace(
        "/*__ARCH_JSON__*/ null",
        json.dumps(payload, ensure_ascii=False).replace("</", "<\\/"),
    )
    (DOCS / "architecture.html").write_text(html, encoding="utf-8")
    print(f"Wrote {DOCS / 'architecture.html'} ({len(files)} files, {len(nodes)} nodes)")


if __name__ == "__main__":
    main()
