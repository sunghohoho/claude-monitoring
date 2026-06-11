# 02. OpenTelemetry 구성 가이드

Claude Code의 OpenTelemetry를 활성화하여 사용량 메트릭(세션, 토큰, 비용, 코드 변경)을 수집하고 CloudWatch로 전달합니다. 대화 내용은 수집하지 않으며, 사용자 귀속은 인증 토큰 기반으로 동작합니다.

---

## 사전 요구사항

| 항목 | 요구사항 |
|------|----------|
| Claude Code | 최신 버전 |
| OTEL Collector | 01-initial-setup에서 배포 완료 |
| 네트워크 | Collector ALB 엔드포인트 접근 가능 |

---

## 단계별 설정 방법

### 1. 텔레메트리 수집 활성화

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
```

### 2. 익스포터 구성 (테스트)

초기 테스트 시 콘솔에 메트릭을 출력하여 확인합니다:

```bash
export OTEL_METRICS_EXPORTER=console
export OTEL_LOGS_EXPORTER=console
```

### 3. 내보내기 간격 설정 (디버깅용)

```bash
export OTEL_METRIC_EXPORT_INTERVAL=10000  # 10초
export OTEL_LOGS_EXPORT_INTERVAL=5000     # 5초
```

### 4. 테스트 실행

```bash
claude -p "hello world"
```

다음 메트릭이 콘솔에 출력되는지 확인:
- `claude_code.session.count`
- `claude_code.token.usage`
- `claude_code.cost.usage`

### 5. OTLP 프로덕션 구성

테스트 확인 후 실제 컬렉터로 전송하도록 변경합니다:

```bash
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=http://<COLLECTOR_ALB_ENDPOINT>
```

컬렉터 엔드포인트 조회:

```bash
aws cloudformation describe-stacks \
  --stack-name claude-code-otel-collector \
  --query 'Stacks[0].Outputs[?OutputKey==`CollectorEndpoint`].OutputValue' \
  --output text
```

### 6. 사용자 귀속 헬퍼 설정

`~/otel-helper.sh` 파일을 생성합니다:

```bash
#!/bin/bash
SYSTEM_USER=$(whoami)
USER_EMAIL="${SYSTEM_USER}@workshop.example.com"
USER_ID=$(echo -n "${SYSTEM_USER}" | sha256sum | cut -c1-32)

DEPARTMENT="${DEPARTMENT:-engineering}"
TEAM_ID="${TEAM_ID:-platform}"
COST_CENTER="${COST_CENTER:-eng-001}"

cat <<JSON
{
  "x-user-email": "${USER_EMAIL}",
  "x-user-id": "${USER_ID}",
  "x-department": "${DEPARTMENT}",
  "x-team-id": "${TEAM_ID}",
  "x-cost-center": "${COST_CENTER}"
}
JSON
```

실행 권한 부여:

```bash
chmod +x ~/otel-helper.sh
```

### 7. Claude Code 설정 파일에 헬퍼 등록

`~/.claude/settings.json`에 추가:

```json
{
  "otelHeadersHelper": "~/otel-helper.sh"
}
```

### 8. 리소스 속성 직접 설정 (대안)

헬퍼 스크립트 대신 환경변수로 직접 설정할 수도 있습니다:

```bash
export OTEL_RESOURCE_ATTRIBUTES="user.email=${USER}@example.com,user.id=$(whoami),department=engineering,team.id=platform,cost_center=eng-123,organization=mycompany"
```

> **형식 규칙**: 값에 공백 불가, `key1=value1,key2=value2` 형식, 공백 대신 밑줄 또는 camelCase 사용.

---

## 수집 메트릭 항목 목록

### 메트릭 (Metrics)

| 메트릭 이름 | 설명 | 단위 |
|---|---|---|
| `claude_code.session.count` | 시작된 CLI 세션 수 | count |
| `claude_code.token.usage` | 사용된 토큰 수 | tokens |
| `claude_code.cost.usage` | 세션 비용 | USD |
| `claude_code.lines_of_code.count` | 수정된 코드 라인 수 | count |
| `claude_code.commit.count` | 생성된 git 커밋 수 | count |
| `claude_code.pull_request.count` | 생성된 풀 리퀘스트 수 | count |
| `claude_code.active_time.total` | 총 활성 시간 | seconds |
| `claude_code.code_edit_tool.decision` | 도구별 수락/거부 결정 | count |

### 이벤트 (Events/Logs)

| 이벤트 이름 | 설명 |
|---|---|
| `claude_code.api_request` | 요청당 비용, 모델, 지연시간, 토큰 분석 |
| `claude_code.api_error` | 오류 메시지, 상태 코드, 재시도 횟수 |
| `claude_code.tool_result` | 도구 실행 시간, 성공/실패 |
| `claude_code.user_prompt` | 프롬프트 길이 및 복잡도 |
| `claude_code.tool_decision` | 도구 유형별 수락/거부 패턴 |

---

## 알림 임계값 추천 설정

| 경보명 | 메트릭 | 임계값 | 기간 | 용도 |
|--------|--------|--------|------|------|
| HighCostUsage | `claude_code.cost.usage` | $1,000 | 24h | 일일 비용 초과 |
| HighTokenUsage | `claude_code.token.usage` | 1,000,000 | 1h | 토큰 과다 사용 |
| SessionSpike | `claude_code.session.count` | 500 | 1h | 비정상 세션 급증 |

경보 생성 예시:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "ClaudeCode-HighCostUsage" \
  --metric-name "claude_code.cost.usage" \
  --namespace "ClaudeCode" \
  --statistic Sum \
  --period 86400 \
  --threshold 1000 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1 \
  --alarm-actions arn:aws:sns:REGION:ACCOUNT:claude-code-alerts
```

---

## 대시보드 연동 방법

OTEL 메트릭이 CloudWatch에 도달하면 자동으로 다음 대시보드에서 시각화됩니다:

1. **CloudWatch 기본 대시보드**: `ClaudeCode` 네임스페이스에서 메트릭 탐색
2. **사용자 정의 대시보드**: 04-dashboard 가이드에서 배포하는 전용 대시보드
3. **CloudWatch Logs Insights**: EMF 로그 기반 실시간 쿼리

CloudWatch에 메트릭 도달 확인:

```bash
aws cloudwatch list-metrics --namespace ClaudeCode
```

---

## 환경변수 전체 요약

프로덕션 환경의 `.bashrc` 또는 `.zshrc`에 추가:

```bash
# Claude Code OTEL 설정
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=http://<COLLECTOR_ALB_ENDPOINT>
export OTEL_METRIC_EXPORT_INTERVAL=60000
export OTEL_LOGS_EXPORT_INTERVAL=30000
export OTEL_RESOURCE_ATTRIBUTES="user.email=${USER}@company.com,user.id=$(whoami),department=engineering,team.id=platform,cost_center=eng-001"
```

---

## AWS 조직 제약 대응

- OTEL Collector는 단일 계정 내 ECS Fargate로 동작하므로 **조직 기능에 의존하지 않음**
- 멤버 계정의 Claude Code 클라이언트는 ALB 엔드포인트로 직접 메트릭 전송
- VPC 피어링 또는 ALB를 퍼블릭으로 노출하여 멤버 계정 접근 허용
- IP 화이트리스트 + 인증 헤더로 보안 유지

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|------|------|------|
| 메트릭 미출력 | `CLAUDE_CODE_ENABLE_TELEMETRY` 미설정 | 환경변수 확인 |
| 컬렉터 연결 실패 | ALB 엔드포인트 미도달 | Security Group 인바운드 4318 포트 확인 |
| 사용자 귀속 없음 | otel-helper 미설정 | settings.json 및 스크립트 확인 |
| CloudWatch 메트릭 없음 | 네임스페이스 필터 | `ClaudeCode` 네임스페이스 확인 |
