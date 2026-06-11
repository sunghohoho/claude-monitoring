# 04. 사용량 대시보드 배포 가이드

Claude Code 모니터링 대시보드를 배포하여 사용 패턴, 비용, 사용자 활동에 대한 실시간 시각화를 제공합니다.

---

## 사전 요구사항

| 항목 | 요구사항 |
|------|----------|
| OTEL Collector | 03-data-pipeline에서 배포 완료 |
| CloudWatch 메트릭 | `ClaudeCode` 네임스페이스에 데이터 수신 중 |
| IAM 권한 | CloudFormation, Lambda, CloudWatch Dashboard 생성 권한 |
| S3 | Lambda 아티팩트 저장용 버킷 |

---

## 대시보드 구성 항목

| 위젯 | 시각화 내용 |
|-------|------------|
| 총 세션 수 | 일/주/월 단위 세션 추이 |
| 토큰 사용량 | 입력/출력/캐시 토큰 분포 |
| 비용 추적 | 일별/주별 비용 추이 및 예측 |
| 활성 사용자 | 고유 사용자 수 및 활동 패턴 |
| 코드 생산성 | 커밋, PR, 코드 라인 변경 추이 |
| API 성능 | 지연시간, 오류율, 요청 처리량 |

---

## 단계별 배포 방법

### 1. 인프라 템플릿 준비

```bash
cd guidance-for-claude-code-with-amazon-bedrock/deployment/infrastructure
```

### 2. Lambda 아티팩트용 S3 버킷 생성

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="claude-code-cfn-artifacts-${ACCOUNT_ID}"

aws s3 mb s3://${BUCKET_NAME}
```

### 3. CloudFormation 패키징

```bash
aws cloudformation package \
  --template-file claude-code-dashboard.yaml \
  --s3-bucket ${BUCKET_NAME} \
  --output-template-file packaged-claude-code-dashboard.yaml
```

### 4. 대시보드 스택 배포

```bash
aws cloudformation deploy \
  --template-file packaged-claude-code-dashboard.yaml \
  --stack-name claude-code-dashboard \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    MetricsRegion=us-east-1
```

**파라미터:**

| 파라미터 | 설명 | 기본값 |
|---------|------|--------|
| MetricsRegion | 메트릭 수집 리전 | us-west-2 |

### 5. 배포 완료 확인

```bash
aws cloudformation describe-stacks \
  --stack-name claude-code-dashboard \
  --query 'Stacks[0].StackStatus' --output text
```

---

## 대시보드 접근

### URL 조회

```bash
aws cloudformation describe-stacks \
  --stack-name claude-code-dashboard \
  --query 'Stacks[0].Outputs[?OutputKey==`DashboardURL`].OutputValue' \
  --output text
```

### 초기 설정

1. 브라우저에서 대시보드 URL 열기
2. 노란색 배너가 표시되면 **"Invoke Lambda functions"** 클릭하여 위젯 활성화
3. 시간 범위를 원하는 기간으로 조정 (기본: 3시간)

---

## 커스텀 대시보드 위젯 추가

CloudWatch 콘솔에서 직접 위젯을 추가할 수 있습니다.

### 팀별 비용 비교 위젯

```json
{
  "metrics": [
    ["ClaudeCode", "claude_code.cost.usage", "team.id", "platform"],
    ["ClaudeCode", "claude_code.cost.usage", "team.id", "frontend"],
    ["ClaudeCode", "claude_code.cost.usage", "team.id", "backend"]
  ],
  "period": 86400,
  "stat": "Sum",
  "title": "팀별 일일 비용"
}
```

### 사용자 활동 히트맵

```json
{
  "metrics": [
    ["ClaudeCode", "claude_code.session.count"]
  ],
  "period": 3600,
  "stat": "Sum",
  "title": "시간대별 세션 활동"
}
```

---

## AWS 조직 제약 대응

- 대시보드는 **단일 계정 CloudWatch**에서 동작 — 조직 기능 불필요
- 멤버 계정 메트릭은 중앙 컬렉터를 통해 이미 수집됨
- CloudWatch cross-account 대시보드를 사용하려면:
  - 멤버 계정에서 `CloudWatch:CrossAccountSharingRole` IAM 역할 생성
  - 중앙 계정에서 cross-account 위젯 추가

### 멤버 계정 공유 역할 (선택)

```bash
# 멤버 계정에서 실행
aws iam create-role \
  --role-name CloudWatch-CrossAccountSharingRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::CENTRAL_ACCOUNT_ID:root"},
      "Action": "sts:AssumeRole"
    }]
  }'
```

---

## 부가 설정 추천

### 자동 새로고침

대시보드 상단에서 자동 새로고침 간격을 1분으로 설정하여 실시간 모니터링.

### 알림 연동

대시보드 메트릭에서 직접 경보를 생성할 수 있습니다:
1. 위젯에서 메트릭 선택
2. Actions → Create alarm
3. SNS 토픽으로 알림 전송 설정

### 대시보드 공유

- **콘솔 공유**: IAM 사용자에게 `cloudwatch:GetDashboard` 권한 부여
- **퍼블릭 공유**: CloudWatch 대시보드 sharing 기능 (read-only 링크 생성)

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|------|------|------|
| 위젯 빈 상태 | Lambda 미호출 | "Invoke Lambda functions" 배너 클릭 |
| 메트릭 없음 | 네임스페이스 미확인 | `ClaudeCode` 네임스페이스에 데이터 있는지 확인 |
| 패키징 실패 | S3 버킷 없음 | 버킷 생성 후 재시도 |
| 권한 오류 | CAPABILITY_NAMED_IAM 미지정 | deploy 명령에 capabilities 추가 |
