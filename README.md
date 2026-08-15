<div align="center">
  <img src="Assets/OpiumWordmark.png" width="680" alt="Opium">
  <br><br>
  <strong>macOS용 로컬 AI 에이전트 플랫폼</strong>
  <br><br>
  <a href="https://github.com/yiseowon/Opium/releases/download/v0.2.0-preview/Opium-macOS-arm64.zip">다운로드</a>
  ·
  <a href="#5분-설치-가이드">설치 가이드</a>
  ·
  <a href="#qwen38-모델-추가">모델 설정</a>
  ·
  <a href="#문제-해결">문제 해결</a>
  <br><br>
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-18181B?style=flat-square&logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-required-7A61F5?style=flat-square">
  <img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="Preview" src="https://img.shields.io/badge/release-0.2.0%20preview-7A61F5?style=flat-square">
</div>

---

## Opium이란?

Opium은 Mac에서 GGUF 언어 모델을 실행하고, 모델의 파일·터미널·웹·메일 도구 사용을 관리하는 네이티브 애플리케이션입니다.

Ollama나 LM Studio처럼 모델을 사용자의 컴퓨터에서 실행하지만, 단순 채팅보다 **도구를 사용해 실제 작업을 완료하는 에이전트 실행**에 초점을 맞춥니다.

- 모델 추론: `llama.cpp`의 `llama-server`
- 기본 검증 모델: `Qwen3.8-27B Q4_K_M`
- 앱과 에이전트 하네스: Swift 6.2, SwiftUI, AppKit
- 모델 통신: OpenAI 호환 HTTP API와 스트리밍
- 데이터 저장: 로컬 Application Support와 작업별 폴더

LangChain, LangGraph, OpenAI Agents SDK는 사용하지 않습니다. 모델 요청 → 도구 호출 → 권한 검사 → 실행 → 결과 반환을 반복하는 하네스를 Swift로 직접 구현했습니다.

## 다운로드

### [Opium 0.2.0 Preview for Apple Silicon 다운로드](https://github.com/yiseowon/Opium/releases/download/v0.2.0-preview/Opium-macOS-arm64.zip)

| 항목 | 내용 |
| --- | --- |
| 파일 | `Opium-macOS-arm64.zip` |
| 대상 | Apple Silicon Mac |
| 최소 운영체제 | macOS 15 |
| 앱 크기 | 약 5MB, 압축 파일 약 2.4MB |
| 포함되지 않는 항목 | GGUF 모델, llama.cpp |
| 서명 | ad-hoc 서명 프리뷰, Developer ID 공증 전 |

모델은 크기와 배포 조건 때문에 앱에 포함하지 않습니다. 아래 안내에 따라 `llama.cpp`와 Qwen GGUF를 별도로 설치해야 합니다.

## 5분 설치 가이드

### 1. 앱 설치

1. 위의 ZIP 파일을 다운로드합니다.
2. 압축을 풀어 나온 `Opium.app`을 **응용 프로그램** 폴더로 이동합니다.
3. Finder에서 `Opium.app`을 Control-클릭하고 **열기**를 선택합니다.
4. 경고 창에서 다시 **열기**를 누릅니다.

프리뷰 버전은 Apple Developer ID 공증 전이므로 일반 더블 클릭 시 macOS가 실행을 막을 수 있습니다. Gatekeeper를 전역으로 끄지 말고 Control-클릭 → 열기 방식을 사용하세요.

### 2. llama.cpp 설치

[Homebrew](https://brew.sh)가 설치된 터미널에서 실행합니다.

```bash
brew install llama.cpp
llama-server --version
```

Opium은 다음 경로에서 `llama-server`를 찾습니다.

```text
/opt/homebrew/bin/llama-server
/usr/local/bin/llama-server
```

### 3. 모델 설치

48GB Apple Silicon Mac에서는 [`Qwen3.8-27B Q4_K_M`](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF)을 기준 모델로 권장합니다.

모델 파일을 다음 폴더에 넣습니다.

```text
~/Library/Application Support/LocalAgent/Models/
```

폴더가 없다면 생성합니다.

```bash
mkdir -p "$HOME/Library/Application Support/LocalAgent/Models"
```

다운로드한 `.gguf` 파일만 해당 폴더로 이동합니다. `mmproj`, `mtp`처럼 보조 파일인 GGUF는 모델 목록에서 자동으로 제외됩니다.

### 4. 첫 실행

1. Opium을 실행합니다.
2. 입력창 오른쪽의 모델 메뉴를 엽니다.
3. **모델 다시 찾기**를 선택합니다.
4. `Qwen3.8 27B`와 원하는 추론 강도를 선택합니다.
5. 메시지를 보내면 모델이 자동으로 로드됩니다.

모델 로드에는 Mac 사양과 파일 크기에 따라 시간이 걸릴 수 있습니다. 사용이 끝나면 오른쪽 아래의 **모델 언로드** 버튼으로 메모리를 회수할 수 있습니다.

## Qwen3.8 모델 추가

Opium은 특정 모델 파일을 저장소에 포함하지 않습니다. `llama-server`에서 실행 가능한 GGUF를 검색해 모델 메뉴에 표시합니다.

현재 확인한 조합:

| 모델 | 상태 |
| --- | --- |
| Qwen3.8-27B Q4_K_M | 주 개발 및 실제 작업 검증 |
| Qwen3-Coder-30B-A3B-Instruct Q4_K_M | 이전 호환 모델 |
| 기타 GGUF | 실행과 도구 호출 품질을 모델별로 확인해야 함 |

모델이 목록에 나타나지 않으면 다음을 확인하세요.

- 파일 확장자가 `.gguf`인지
- 다운로드가 완료되어 `.aria2` 임시 파일이 남지 않았는지
- 모델 파일이 정확한 Models 폴더 안에 있는지
- 모델 메뉴에서 **모델 다시 찾기**를 실행했는지

## 주요 기능

### 대화와 작업

- 스트리밍 응답과 Markdown 표시
- 목록, 인라인 코드와 복사 가능한 코드 블록
- 이미지와 파일 첨부
- 응답 중단과 다음 프롬프트 예약
- 턴 전체 토큰, 생성 속도와 경과 시간
- 처음 몇 차례의 대화를 이용한 작업 제목 생성

### 에이전트 도구

- 파일과 폴더 검색·읽기·작성·이동
- 파일을 휴지통으로 이동
- 터미널 명령 실행과 결과 반환
- 웹 검색과 웹페이지 읽기
- Apple Mail 검색
- 작업 중 사용자 선택이 필요할 때 선택지 카드 표시

### 파일 변경 추적

- 작업 중인 파일 이름 표시
- 파일별 실시간 `+추가 / -삭제` 줄 수
- 최종 변경 파일 목록
- 명령·빌드·검증 결과 기록

### 작업 관리

- 새 작업, 프로젝트, 반복 작업과 예약 작업 기록
- 작업 이름 변경과 삭제
- 작업별 전용 로컬 폴더
- 별도 폴더가 없을 때 `~/LLM/날짜/작업-ID` 자동 생성
- 대화와 설정의 로컬 저장

### 모델과 시스템

- GGUF 모델 검색·선택·재검색
- 첫 메시지에서 자동 로드
- 명시적인 모델 언로드
- Feather, Light, Medium, High, Extra High, Ultra 작업 예산
- 시스템 RAM, 모델 RSS와 Opium 메모리
- CPU·GPU 사용률과 macOS 열 상태
- 컨텍스트 사용량과 양자화 정보

## 에이전트 실행 구조

```text
사용자 요청
  ↓
시스템 지침 + 대화 기록 + 활성화된 Skill 구성
  ↓
llama-server에 스트리밍 요청
  ↓
텍스트 또는 tool_call 수신
  ↓
경로 및 작업 권한 검사
  ↓
Swift 도구 실행
  ↓
결과를 tool 메시지로 모델에 반환
  ↓
추가 도구 호출 또는 최종 응답
```

모델이 도구를 한 번 호출했다고 작업을 종료하지 않습니다. 도구 결과를 다시 모델에 전달하고, 요청이 끝날 때까지 같은 턴에서 실행을 계속합니다.

## 권한과 활동 기록

Opium의 승인 정책과 macOS 시스템 권한은 서로 다릅니다.

- **Opium 승인 정책**: 모델이 요청한 파일 변경이나 명령을 앱이 실행할지 결정합니다.
- **macOS 권한**: Mail, 개인 폴더, 자동화 등의 접근을 운영체제가 결정합니다.

전체 액세스는 Opium 내부의 반복 승인 질문을 생략하지만 macOS 개인정보 보호 설정을 우회하지 않습니다.

실제 도구 실행은 다음 세 단계로 표시합니다.

| 레벨 | 범위 | 예시 |
| --- | --- | --- |
| Level 1 | 일반 작업 공간 | 프로젝트 파일 읽기와 수정 |
| Level 2 | 개인·외부 데이터 | 웹, 메일, 사용자 문서 |
| Level 3 | 시스템 영향 작업 | 터미널, 삭제, 민감 경로 |

## 기본 Kit

| Kit | 역할 |
| --- | --- |
| Adrenaline Kit | 파일·웹·메일을 포함한 기본 에이전트 도구 지침 |
| Caffeine Kit | 짧은 응답, 최소 도구 호출과 토큰 절약 지침 |
| Melatonin Kit | 16K 컨텍스트와 제한된 스레드를 사용하는 저전력 실행 모드 |

Opium은 Codex 형식의 `.codex-plugin/plugin.json`과 `SKILL.md`를 읽습니다. 현재는 활성화된 Skill을 모델 지침에 적용하며, 외부 MCP 프로세스와 Hooks의 자동 실행은 아직 제공하지 않습니다.

## 기준 개발 환경

| 항목 | 사양 |
| --- | --- |
| Mac | MacBook Pro (`Mac17,8`) |
| 칩 | Apple M5 Pro, CPU 18코어 |
| 통합 메모리 | 48GB |
| 운영체제 | macOS 26.6.1 |
| 모델 | Qwen3.8-27B Q4_K_M |
| 컨텍스트 | 일반 32K, Melatonin 16K |
| 관찰된 생성 속도 | 약 10–13 tok/s |
| 실행 중 모델 RSS | 약 20.9GB |

측정값은 llama.cpp 버전, 프롬프트, 컨텍스트와 백그라운드 부하에 따라 달라집니다. 메모리가 48GB보다 적다면 더 작은 모델이나 더 높은 압축률의 양자화를 사용하세요.

## 문제 해결

### GGUF 모델이 없다고 표시됨

모델 파일을 `~/Library/Application Support/LocalAgent/Models/`에 넣고 **모델 다시 찾기**를 선택하세요.

### llama-server를 찾지 못함

```bash
brew install llama.cpp
which llama-server
```

Apple Silicon Homebrew의 기본 경로는 `/opt/homebrew/bin/llama-server`입니다.

### 앱이 열리지 않음

Finder에서 앱을 Control-클릭 → **열기**를 사용하세요. 시스템 설정에서 Gatekeeper를 전역으로 해제할 필요는 없습니다.

### 모델이 너무 느리거나 메모리가 부족함

- 더 작은 GGUF 모델 선택
- 더 높은 압축률의 양자화 사용
- Melatonin Kit 활성화
- 불필요한 앱 종료
- 작업 후 모델 언로드

### 메일이나 개인 폴더에 접근할 수 없음

시스템 설정 → 개인정보 보호 및 보안에서 Opium에 필요한 권한을 허용해야 합니다. Opium의 전체 액세스 설정만으로 macOS 권한이 자동 승인되지는 않습니다.

## 소스에서 실행

요구 사항:

- macOS 15 이상
- Swift 6.2 이상
- llama.cpp
- GGUF 모델

```bash
git clone https://github.com/yiseowon/Opium.git
cd Opium
swift build
.build/debug/LocalAgent --self-test
swift run LocalAgent
```

## 현재 제한 사항

- Apple Silicon 전용 프리뷰입니다.
- Developer ID 서명과 Apple 공증이 완료되지 않았습니다.
- 모델 다운로드 관리자는 아직 제공하지 않습니다.
- 외부 MCP 서버와 Hooks는 자동 실행하지 않습니다.
- 반복·예약 작업의 완전한 백그라운드 스케줄러는 개발 중입니다.
- 에이전트 품질은 선택한 모델의 tool calling과 지시 준수 능력에 따라 달라집니다.
- 중요한 파일에는 백업을 사용하고 처음에는 테스트 폴더에서 실행하세요.

## 라이선스

현재 별도의 오픈소스 라이선스가 부여되지 않았습니다. 소스 사용과 재배포 조건은 정식 공개 전에 추가될 예정입니다.
