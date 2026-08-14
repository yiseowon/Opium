<div align="center">
  <img src="Assets/OpiumIcon.png" width="96" alt="Opium 앱 아이콘">
  <h1>Opium</h1>
  <p><strong>Mac 안에서 모델이 생각하고, 도구를 사용하고, 작업을 끝내는 로컬 AI 에이전트.</strong></p>
  <p>
    <img alt="macOS" src="https://img.shields.io/badge/macOS-15%2B-111111?style=flat-square&logo=apple">
    <img alt="Swift" src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift&logoColor=white">
    <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-권장-7A61F5?style=flat-square">
    <img alt="Status" src="https://img.shields.io/badge/status-preview-7A61F5?style=flat-square">
  </p>
</div>

Opium은 GGUF 로컬 LLM을 대화창에만 가두지 않습니다. 모델이 파일을 읽고 수정하며, 명령을 검증하고, 웹과 메일 도구를 사용하는 전 과정을 네이티브 macOS 인터페이스에서 관리합니다.

모델 추론과 대화 기록은 기본적으로 사용자의 Mac에서 처리됩니다. 현재 프리뷰 버전은 `Qwen3.8-27B Q4_K_M`과 `llama.cpp` 조합을 중심으로 개발·검증하고 있습니다.

![Opium 메인 화면](Assets/Screenshots/opium-conversation.jpg)

## 왜 Opium인가요?

### 로컬 모델을 실제 작업자로

단순 채팅뿐 아니라 파일 탐색·작성, 터미널 검증, 웹 검색과 Apple Mail 검색을 하나의 작업 흐름으로 연결합니다. 작업별 전용 폴더를 사용하고, 변경한 파일과 `+/-` 줄 수를 화면에 남깁니다.

### 무엇을 하는지 항상 보이게

모델의 내부 사고를 그대로 노출하는 대신 사용자가 이해할 수 있는 짧은 진행 설명, 현재 실행 중인 도구, 접근 경로, 보안 레벨과 결과를 표시합니다. 응답은 언제든 중단할 수 있고 다음 프롬프트를 예약해 이어서 실행할 수 있습니다.

### Mac 리소스까지 한 화면에서

모델 메모리, 시스템 RAM, CPU·GPU 사용률, 열 상태, 양자화와 컨텍스트 사용량을 실시간으로 확인할 수 있습니다.

## 주요 기능

- SwiftUI 기반 네이티브 macOS 인터페이스
- GGUF 모델 자동 검색, 전환, 로드와 언로드
- `llama.cpp` OpenAI 호환 스트리밍 추론
- Feather부터 Ultra까지 조절 가능한 추론 강도
- Markdown, 목록 카드, 복사 가능한 코드 블록 렌더링
- 턴 전체 토큰·생성 속도·소요 시간 통합 표시
- 응답 중단과 후속 프롬프트 예약
- 파일 읽기·검색·작성·이동·휴지통 처리
- 파일별 실시간 `+추가 / -삭제` 줄 수
- 터미널 명령 실행과 결과 검증
- 웹 검색·페이지 읽기와 Apple Mail 검색
- 경로와 작업 종류에 따른 3단계 보안 활동 로그
- 작업별 로컬 폴더와 대화 기록 저장
- 모델 및 시스템 리소스 모니터링

## 플러그인과 MCP

Opium은 Codex 형식의 로컬 플러그인 구조를 읽습니다. 기본 번들인 **Adrenaline Kit**은 파일·웹·메일 에이전트 도구를 Opium의 권한 및 활동 로그 안에서 제공합니다.

![Opium 플러그인 화면](Assets/Screenshots/opium-plugins.jpg)

플러그인 화면에는 Gmail, Google Drive, Calendar, Notion, GitHub, Slack, Linear, Figma, Dropbox, PostgreSQL, Sentry, Stripe 등 인기 MCP 연결 카탈로그가 포함되어 있습니다. 카탈로그 항목은 실제 계정 또는 MCP 런타임이 연결되기 전까지 `연결 필요`로 명확히 표시됩니다.

```text
my-plugin/
├── .codex-plugin/
│   └── plugin.json
├── skills/
│   └── my-skill/
│       └── SKILL.md
├── .mcp.json       # 선택
└── hooks/          # 선택
```

현재는 활성화된 플러그인의 `SKILL.md`를 모델 지침에 적용합니다. 외부 MCP 프로세스와 Hooks는 안전한 실행 수명 주기와 권한 경계가 완성되기 전까지 자동 실행하지 않습니다.

## 시작하기

### 요구 사항

- Apple Silicon Mac 권장
- macOS 15 이상
- Swift 6.2 이상
- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- 실행할 GGUF 모델

### 1. llama.cpp 설치

```bash
brew install llama.cpp
llama-server --version
```

### 2. 모델 추가

저장소의 `Models` 폴더에 `.gguf` 파일을 넣습니다.

```text
Opium/
└── Models/
    └── your-model.gguf
```

모델 파일은 크기와 배포 조건 때문에 Git에 포함되지 않습니다. 48GB Apple Silicon Mac에서는 [`ggml-org/Qwen3.8-27B-GGUF`](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF)의 `Q4_K_M`을 우선 권장합니다.

### 3. 빌드 및 실행

```bash
swift run LocalAgent
```

첫 메시지를 보내면 선택한 모델이 자동으로 로드됩니다. 새 모델을 추가한 뒤 입력창의 모델 메뉴에서 **모델 다시 찾기**를 선택하면 앱을 재설치하지 않고 전환할 수 있습니다.

## 권한과 안전

Opium은 읽기와 변경 작업을 구분하고, 실제 도구 실행을 보안 활동 로그에 남깁니다.

- 일반 작업 폴더 접근은 레벨 1로 분류합니다.
- 개인 데이터·웹·메일 접근은 레벨 2로 표시합니다.
- 터미널, 삭제, 시스템 민감 경로는 레벨 3으로 강조합니다.
- 파일 작성·이동·삭제와 터미널 명령은 선택한 정책에 따라 승인을 요청합니다.
- 전체 액세스는 Opium 내부 승인 질문을 생략하지만 macOS 자체 개인정보 보호 정책을 우회하지 않습니다.

커뮤니티 모델이 생성한 명령은 항상 정확하거나 안전하다고 보장할 수 없습니다. 중요한 파일은 백업하고, 처음에는 테스트 폴더에서 사용해 주세요.

## 개발 및 검증

```bash
swift build
.build/debug/LocalAgent --self-test
```

대화와 설정은 사용자의 Application Support 영역에 저장됩니다. 모델은 저장소의 `Models` 폴더와 앱 지원 폴더에서 검색합니다.

## 브랜드

Opium의 대표 색상은 **Opium Purple `#7A61F5`**입니다. 앱의 강조 색상은 이 색상에서 명도·채도·투명도를 조절해 파생합니다.

## 현재 상태

Opium은 제품화 전 프리뷰입니다. UI, 저장 형식, 권한 정책과 플러그인 런타임은 변경될 수 있습니다.

## 라이선스

아직 별도의 오픈소스 라이선스를 부여하지 않았습니다. 코드 사용 및 재배포 조건은 정식 공개 전에 추가될 예정입니다.
