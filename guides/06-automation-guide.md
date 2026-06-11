# 06. 자동화 및 배포 가이드

Phase 1~5에서 구성한 모든 인프라를 자동화 스크립트로 일괄 배포합니다. CloudFormation 스택 순서 관리, 사전 조건 검증, 롤백 방법을 포함합니다.

---

## 전체 자동화 흐름

```
┌─────────────────────────────────────────────────────────────┐
│                    deploy.sh 실행                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. 사전 조건 검증                                           │
│     ├─ AWS CLI 버전 확인                                     │
│     ├─ IAM 권한 확인                                         │
│     ├─ VPC/서브넷 존재 확인                                   │
│     └─ ECS 서비스 역할 확인                                   │
│                                                             │
│  2. OTEL Collector 배포 (03-data-pipeline)                   │
│     └─ ECS Fargate + ALB + CloudWatch 통합                  │
│                                                             │
│  3. 대시보드 배포 (04-dashboard)                              │
│     └─ Lambda + CloudWatch Dashboard                        │
│                                                             │
│  4. 분석 파이프라인 배포 (05-report)                           │
│     └─ Firehose + S3 + Athena                              │
│                                                             │
│  5. 배포 후 검증                                             │
│     ├─ 각 스택 상태 확인                                      │
│     ├─ 엔드포인트 헬스체크                                    │
│     └─ 출력값 표시                                           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 배포 스크립트

### deploy.sh

```bash
#!/bin/bash
set -euo pipefail

# ============================================================
# Claude Code on Bedrock — 모니터링 인프라 자동 배포
# ============================================================

REGION="${AWS_REGION:-us-east-1}"
STACK_PREFIX="claude-code"
REPO_URL="https://github.com/aws-solutions-library-samples/guidance-for-claude-code-with-amazon-bedrock.git"
REPO_DIR="guidance-for-claude-code-with-amazon-bedrock"

echo "============================================================"
echo " Claude Code Monitoring — 자동 배포"
echo " Region: $REGION"
echo "============================================================"

# ------------------------------------------------------------
# 1. 사전 조건 검증
# ------------------------------------------------------------
echo ""
echo "[1/5] 사전 조건 검증..."

# AWS CLI 버전
AWS_VERSION=$(aws --version 2>&1 | cut -d/ -f2 | cut -d' ' -f1)
echo "  ✓ AWS CLI: $AWS_VERSION"

# 계정 확인
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "  ✓ Account: $ACCOUNT_ID"

# VPC 확인
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text --region $REGION)
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "  ✗ 기본 VPC를 찾을 수 없습니다. VPC_ID 환경변수를 설정하세요."
  exit 1
fi
echo "  ✓ VPC: $VPC_ID"

# 서브넷 확인 (최소 2개)
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
  --query "Subnets[0:2].SubnetId" --output text --region $REGION | tr '\t' ',')
SUBNET_COUNT=$(echo "$SUBNET_IDS" | tr ',' '\n' | wc -l)
if [ "$SUBNET_COUNT" -lt 2 ]; then
  echo "  ✗ 서브넷이 2개 미만입니다."
  exit 1
fi
echo "  ✓ Subnets: $SUBNET_IDS"

# ECS 서비스 역할
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true
echo "  ✓ ECS 서비스 역할 확인"

# ------------------------------------------------------------
# 2. 인프라 템플릿 준비
# ------------------------------------------------------------
echo ""
echo "[2/5] 인프라 템플릿 준비..."

if [ ! -d "$REPO_DIR" ]; then
  git clone --depth 1 "$REPO_URL"
fi
cd "$REPO_DIR/deployment/infrastructure"
echo "  ✓ 템플릿 준비 완료"

# ------------------------------------------------------------
# 3. OTEL Collector 배포
# ------------------------------------------------------------
echo ""
echo "[3/5] OTEL Collector 배포..."

aws cloudformation deploy \
  --template-file otel-collector.yaml \
  --stack-name ${STACK_PREFIX}-otel-collector \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    VpcId=$VPC_ID \
    SubnetIds=$SUBNET_IDS \
    EnableAnalytics=true \
  --region $REGION \
  --no-fail-on-empty-changeset

COLLECTOR_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name ${STACK_PREFIX}-otel-collector \
  --query 'Stacks[0].Outputs[?OutputKey==`CollectorEndpoint`].OutputValue' \
  --output text --region $REGION)
echo "  ✓ Collector Endpoint: $COLLECTOR_ENDPOINT"

# ------------------------------------------------------------
# 4. 대시보드 배포
# ------------------------------------------------------------
echo ""
echo "[4/5] 대시보드 배포..."

BUCKET_NAME="${STACK_PREFIX}-cfn-artifacts-${ACCOUNT_ID}"
aws s3 mb "s3://${BUCKET_NAME}" --region $REGION 2>/dev/null || true

aws cloudformation package \
  --template-file claude-code-dashboard.yaml \
  --s3-bucket "${BUCKET_NAME}" \
  --output-template-file packaged-dashboard.yaml \
  --region $REGION

aws cloudformation deploy \
  --template-file packaged-dashboard.yaml \
  --stack-name ${STACK_PREFIX}-dashboard \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    MetricsRegion=$REGION \
  --region $REGION \
  --no-fail-on-empty-changeset

DASHBOARD_URL=$(aws cloudformation describe-stacks \
  --stack-name ${STACK_PREFIX}-dashboard \
  --query 'Stacks[0].Outputs[?OutputKey==`DashboardURL`].OutputValue' \
  --output text --region $REGION)
echo "  ✓ Dashboard: $DASHBOARD_URL"

# ------------------------------------------------------------
# 5. 분석 파이프라인 배포
# ------------------------------------------------------------
echo ""
echo "[5/5] 분석 파이프라인 배포..."

aws cloudformation deploy \
  --template-file analytics-pipeline.yaml \
  --stack-name ${STACK_PREFIX}-analytics \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    DashboardStackName=${STACK_PREFIX}-dashboard \
  --region $REGION \
  --no-fail-on-empty-changeset

ATHENA_URL=$(aws cloudformation describe-stacks \
  --stack-name ${STACK_PREFIX}-analytics \
  --query 'Stacks[0].Outputs[?OutputKey==`AthenaConsoleUrl`].OutputValue' \
  --output text --region $REGION)
echo "  ✓ Athena: $ATHENA_URL"

# ------------------------------------------------------------
# 완료
# ------------------------------------------------------------
echo ""
echo "============================================================"
echo " 배포 완료!"
echo "============================================================"
echo ""
echo " OTEL Endpoint : $COLLECTOR_ENDPOINT"
echo " Dashboard     : $DASHBOARD_URL"
echo " Athena        : $ATHENA_URL"
echo ""
echo " 클라이언트 설정:"
echo "   export CLAUDE_CODE_ENABLE_TELEMETRY=1"
echo "   export OTEL_METRICS_EXPORTER=otlp"
echo "   export OTEL_LOGS_EXPORTER=otlp"
echo "   export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf"
echo "   export OTEL_EXPORTER_OTLP_ENDPOINT=$COLLECTOR_ENDPOINT"
echo ""
echo "============================================================"
```

---

## 사용 방법

### 기본 배포

```bash
chmod +x deploy.sh
./deploy.sh
```

### 리전 지정

```bash
AWS_REGION=us-west-2 ./deploy.sh
```

### 개별 스택만 배포

필요 시 스크립트 내 특정 단계만 실행하거나, 개별 `aws cloudformation deploy` 명령을 실행합니다.

---

## 롤백 방법

### 전체 롤백 (역순)

```bash
# 분석 파이프라인 삭제
aws cloudformation delete-stack --stack-name claude-code-analytics

# 대시보드 삭제
aws cloudformation delete-stack --stack-name claude-code-dashboard

# OTEL Collector 삭제
aws cloudformation delete-stack --stack-name claude-code-otel-collector

# S3 아티팩트 버킷 삭제 (비어있어야 함)
aws s3 rb s3://claude-code-cfn-artifacts-${ACCOUNT_ID} --force

# 삭제 완료 대기
aws cloudformation wait stack-delete-complete --stack-name claude-code-analytics
aws cloudformation wait stack-delete-complete --stack-name claude-code-dashboard
aws cloudformation wait stack-delete-complete --stack-name claude-code-otel-collector
```

### 개별 스택 롤백

```bash
# 이전 버전으로 롤백
aws cloudformation rollback-stack --stack-name claude-code-otel-collector
```

### 실패한 스택 정리

```bash
# DELETE_FAILED 상태의 스택 강제 삭제
aws cloudformation delete-stack \
  --stack-name claude-code-otel-collector \
  --retain-resources LogGroup
```

---

## GitHub Actions CI/CD (선택)

### .github/workflows/deploy.yml

```yaml
name: Deploy Monitoring Infrastructure

on:
  push:
    branches: [main]
    paths:
      - 'deployment/infrastructure/**'
  workflow_dispatch:
    inputs:
      region:
        description: 'AWS Region'
        default: 'us-east-1'

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/GitHubActionsDeployRole
          aws-region: ${{ inputs.region || 'us-east-1' }}

      - name: Deploy
        run: |
          chmod +x deploy.sh
          ./deploy.sh
```

### 필요한 GitHub Secrets

| Secret | 값 |
|--------|-----|
| AWS_ACCOUNT_ID | 대상 AWS 계정 ID |

### IAM 역할 (OIDC)

GitHub Actions에서 사용할 IAM 역할:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/YOUR_REPO:*"
      }
    }
  }]
}
```

---

## CFN 파라미터 요약

| 스택 | 파라미터 | 설명 |
|------|---------|------|
| otel-collector | VpcId | VPC ID |
| otel-collector | SubnetIds | 서브넷 ID (콤마 구분) |
| otel-collector | EnableAnalytics | 분석 파이프라인 연동 (true/false) |
| dashboard | MetricsRegion | 메트릭 수집 리전 |
| analytics | DashboardStackName | 대시보드 스택 이름 (크로스 참조) |

---

## 비용 예상

| 리소스 | 월 예상 비용 | 비고 |
|--------|-------------|------|
| ECS Fargate (0.25 vCPU, 0.5GB) | ~$10 | 컬렉터 1 태스크 |
| ALB | ~$16 + LCU | 시간당 $0.0225 |
| CloudWatch Metrics | ~$3-10 | 커스텀 메트릭 수 기반 |
| CloudWatch Logs | ~$0.50/GB | 수집량 기반 |
| S3 | ~$0.023/GB | 분석 데이터 저장 |
| Athena | $5/TB scanned | 쿼리 시에만 과금 |
| **합계 (소규모 팀)** | **~$30-50/월** | 사용자 10명 기준 |

---

## AWS 조직 제약 정리

| 항목 | All Features 필요 여부 | 대안 |
|------|----------------------|------|
| 스택 배포 | 불필요 | 각 계정에서 독립 배포 |
| 멤버 계정 수집 | 불필요 | ALB 엔드포인트 직접 전송 |
| 중앙 대시보드 | 불필요 | cross-account observability |
| SCP 정책 | 필요 (사용 불가) | 계정별 IAM 정책으로 대체 |
| 조직 CloudTrail | 필요 (사용 불가) | 계정별 Trail 생성 |
