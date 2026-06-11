#!/bin/bash
set -euo pipefail

# ============================================================
# Claude Code on Bedrock — 모니터링 인프라 자동 배포
# Usage: ./deploy.sh
#        AWS_REGION=us-west-2 ./deploy.sh
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

AWS_VERSION=$(aws --version 2>&1 | cut -d/ -f2 | cut -d' ' -f1)
echo "  ✓ AWS CLI: $AWS_VERSION"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "  ✓ Account: $ACCOUNT_ID"

VPC_ID="${VPC_ID:-$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text --region $REGION)}"
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "  ✗ VPC를 찾을 수 없습니다. VPC_ID 환경변수를 설정하세요."
  exit 1
fi
echo "  ✓ VPC: $VPC_ID"

SUBNET_IDS="${SUBNET_IDS:-$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
  --query "Subnets[0:2].SubnetId" --output text --region $REGION | tr '\t' ',')}"
SUBNET_COUNT=$(echo "$SUBNET_IDS" | tr ',' '\n' | wc -l)
if [ "$SUBNET_COUNT" -lt 2 ]; then
  echo "  ✗ 서브넷이 2개 미만입니다. SUBNET_IDS 환경변수를 설정하세요."
  exit 1
fi
echo "  ✓ Subnets: $SUBNET_IDS"

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
echo "  ✓ Collector: $COLLECTOR_ENDPOINT"

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
