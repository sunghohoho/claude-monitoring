# 01. 초기 설정 가이드

Claude Code on Bedrock 모니터링 시스템의 초기 환경을 구성합니다. AWS 조직에서 All Features 활성화 없이도 중앙 관리 계정(Management Account)에서 모니터링을 구성하고, 멤버 계정이 이를 참조할 수 있도록 설계합니다.

---

## 사전 요구사항

| 항목 | 요구사항 |
|------|----------|
| AWS CLI | v2.x 이상 |
| AWS 계정 | Management Account 접근 권한 |
| IAM 권한 | CloudFormation, ECS, CloudWatch, S3, IAM 생성 권한 |
| VPC | 퍼블릭 서브넷 2개 이상 (OTEL Collector ALB용) |
| Claude Code | 최신 버전 설치 완료 |

---

## 모니터링 성숙도 단계

| 단계 | 기능 | 설명 |
|------|------|------|
| 1 | CloudWatch | 기본 자동 메트릭, 설정 불필요 |
| 2 | 호출 로깅 | 모델 호출 로깅 활성화 — 상세 감사 추적 |
| 3 | OpenTelemetry | 컬렉터 배포 — 사용자 귀속 + 코드 메트릭 |
| 4 | 대시보드 | 실시간 시각화 |
| 5 | 분석 | 데이터 레이크 — 히스토리 SQL 쿼리 |
| 6 | 할당량 | 사용량 추적 및 비용 제어 |

---

## 아키텍처 선택: 중앙 모드

이 가이드는 **중앙 모드(Central Mode)**를 기준으로 합니다.

| 항목 | 사이드카 모드 | 중앙 모드 (본 가이드) |
|------|-------------|---------------------|
| 데이터 흐름 | Client → localhost:4318 → Local Collector → CloudWatch | Client → ALB → ECS Collector → CloudWatch + EMF logs |
| 인프라 | 서버 측 네트워킹 불필요, Go 1.23+ 필요 | VPC + ECS Fargate + ALB |
| 히스토리 분석 | 불가 | S3 + Athena SQL 파이프라인 |

---

## 단계별 설정 방법

### 1. AWS CLI 구성 확인

```bash
aws sts get-caller-identity
```

Management Account의 자격증명이 반환되는지 확인합니다.

### 2. 기본 VPC 및 서브넷 확인

```bash
# 기본 VPC ID 조회
aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text

# 서브넷 ID 조회 (최소 2개 필요)
aws ec2 describe-subnets --filters "Name=default-for-az,Values=true" \
  --query "Subnets[].SubnetId" --output text
```

### 3. ECS 서비스 연결 역할 생성

```bash
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com
```

> 이미 존재하면 오류가 반환되지만 무시해도 됩니다.

### 4. 인프라 템플릿 가져오기

```bash
git clone https://github.com/aws-solutions-library-samples/guidance-for-claude-code-with-amazon-bedrock.git
cd guidance-for-claude-code-with-amazon-bedrock/deployment/infrastructure
```

### 5. 모델 호출 로깅 활성화 (선택)

Bedrock 콘솔 → Settings → Model invocation logging에서:
- 로그 대상: CloudWatch Logs
- 로그 그룹: `/aws/bedrock/model-invocations`
- 전체 요청/응답 데이터 및 메타데이터 캡처

---

## AWS 조직 제약 사항 및 대응 방법

### 제약: All Features 활성화 불가

| 영향 받는 기능 | 대안 |
|---------------|------|
| AWS Organizations SCP | 개별 계정 IAM 정책으로 대체 |
| 조직 단위 CloudTrail | 계정별 CloudTrail 구성 |
| Cross-account 자동 설정 | CloudWatch cross-account observability (계정별 수동 연결) |

### 멤버 계정 모니터링 방법

All Features 없이도 **CloudWatch cross-account observability**를 사용할 수 있습니다:

1. **중앙 계정 (Monitoring Account)**: CloudWatch 설정 → Cross-account observability → Monitoring account로 설정
2. **멤버 계정 (Source Account)**: CloudWatch 설정 → Cross-account observability → Source account로 링크 생성

```bash
# 멤버 계정에서 실행
aws cloudwatch put-metric-stream \
  --name claude-code-metrics-stream \
  --output-format opentelemetry1.0 \
  --include-filters '[{"Namespace":"ClaudeCode"}]' \
  --firehose-arn arn:aws:firehose:REGION:CENTRAL_ACCOUNT:deliverystream/NAME
```

> 조직 수준 위임 없이도 각 멤버 계정이 개별적으로 중앙 계정에 메트릭을 전송할 수 있습니다.

---

## 부가 설정 추천 항목

### CloudWatch 경보 기본 설정

| 경보 | 임계값 | 기간 |
|------|--------|------|
| 일일 비용 초과 | $1,000 | 24시간 |
| 시간당 토큰 사용량 | 1,000,000 tokens | 1시간 |
| 컬렉터 헬스체크 실패 | 3회 연속 | 5분 |

### 보안 강화

- ALB에 WAF 연결 (IP 화이트리스트)
- OTEL Collector 엔드포인트에 인증 헤더 추가
- CloudWatch Logs 암호화 (KMS CMK)
- S3 버킷 버전관리 및 암호화 활성화

### 태깅 전략

모든 리소스에 다음 태그 적용:

```
Project: claude-code-monitoring
Environment: production
ManagedBy: cloudformation
CostCenter: <부서코드>
```

---

## 빠른 배포 (원커맨드)

```bash
# 변수 설정
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=default-for-az,Values=true" --query "Subnets[0:2].SubnetId" --output text | tr '\t' ',')

# ECS 역할 생성 (이미 있으면 무시)
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true

# 템플릿 클론 및 배포
git clone https://github.com/aws-solutions-library-samples/guidance-for-claude-code-with-amazon-bedrock.git
cd guidance-for-claude-code-with-amazon-bedrock/deployment/infrastructure

aws cloudformation deploy \
  --template-file otel-collector.yaml \
  --stack-name claude-code-otel-collector \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    VpcId=$VPC_ID \
    SubnetIds=$SUBNET_IDS \
    EnableAnalytics=true
```
