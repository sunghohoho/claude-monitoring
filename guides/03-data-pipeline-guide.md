# 03. 데이터 수집 파이프라인 가이드

OTEL Collector를 AWS에 배포하고, CloudWatch로 메트릭을 전달하며, CloudWatch Logs Insights를 통해 실시간 쿼리가 가능한 수집 파이프라인을 구성합니다.

---

## 사전 요구사항

| 항목 | 요구사항 |
|------|----------|
| VPC | 퍼블릭 서브넷 2개 이상 |
| ECS 서비스 역할 | 01-setup에서 생성 완료 |
| 인프라 템플릿 | 저장소 클론 완료 |

---

## 단계별 설정 방법

### 1. 인프라 템플릿 준비

```bash
git clone https://github.com/aws-solutions-library-samples/guidance-for-claude-code-with-amazon-bedrock.git
cd guidance-for-claude-code-with-amazon-bedrock/deployment/infrastructure
```

### 2. VPC 및 서브넷 ID 조회

```bash
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)

SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=default-for-az,Values=true" \
  --query "Subnets[0:2].SubnetId" --output text | tr '\t' ',')

echo "VPC: $VPC_ID"
echo "Subnets: $SUBNET_IDS"
```

### 3. OTEL Collector 스택 배포

```bash
aws cloudformation deploy \
  --template-file otel-collector.yaml \
  --stack-name claude-code-otel-collector \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    VpcId=$VPC_ID \
    SubnetIds=$SUBNET_IDS \
    EnableAnalytics=true
```

### 4. 배포 완료 확인

```bash
aws cloudformation describe-stacks \
  --stack-name claude-code-otel-collector \
  --query 'Stacks[0].StackStatus' --output text
```

`CREATE_COMPLETE` 또는 `UPDATE_COMPLETE`가 반환되어야 합니다.

---

## 생성되는 리소스

| 리소스 | 역할 |
|--------|------|
| ECS Fargate 서비스 | OpenTelemetry Collector 실행 |
| Application Load Balancer | 클라이언트로부터 OTLP 메트릭 수신 (포트 4318) |
| CloudWatch 통합 | 메트릭을 CloudWatch Metrics로 전달 |
| CloudWatch Logs | EMF 형식 로그 저장 (`/aws/claude-code/metrics`) |
| 자동 확장 | CPU/메모리 기반 스케일링 |
| Security Group | ALB 인바운드 제어 |

---

## 엔드포인트 확인 및 테스트

### 컬렉터 엔드포인트 조회

```bash
ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name claude-code-otel-collector \
  --query 'Stacks[0].Outputs[?OutputKey==`CollectorEndpoint`].OutputValue' \
  --output text)
echo $ENDPOINT
```

### 엔드포인트 동작 테스트

```bash
curl -X POST $ENDPOINT/v1/metrics \
  -H "Content-Type: application/json" \
  -d "{\"resourceMetrics\":[{\"scopeMetrics\":[{\"metrics\":[{\"name\":\"test.metric\",\"sum\":{\"dataPoints\":[{\"asInt\":\"42\",\"timeUnixNano\":\"$(date +%s)000000000\"}]}}]}]}]}"
```

성공 응답: `{"partialSuccess":{}}`

### CloudWatch 메트릭 도달 확인

```bash
aws cloudwatch list-metrics --namespace ClaudeCode
```

### CloudWatch Logs 실시간 확인

```bash
aws logs tail /aws/claude-code/metrics --follow
```

---

## CloudWatch Insights 쿼리

`/aws/claude-code/metrics` 로그 그룹에서 실행합니다.

### 사용자별 토큰 사용량

```sql
fields @timestamp, user.id, claude_code.token.usage
| stats sum(claude_code.token.usage) by user.id
| sort by sum desc
```

### 부서별 비용 추세

```sql
fields @timestamp, department, claude_code.cost.usage
| filter @message like /claude_code.cost.usage/
| stats sum(claude_code.cost.usage) as total_cost by department
| sort by total_cost desc
```

### 시간대별 세션 분포

```sql
fields @timestamp, claude_code.session.count
| stats count(*) as sessions by bin(1h)
| sort @timestamp asc
```

---

## 알림 설정

### 일일 비용 초과 경보

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "ClaudeCode-HighCostUsage" \
  --alarm-description "일일 비용 $1000 초과 시 알림" \
  --metric-name "claude_code.cost.usage" \
  --namespace "ClaudeCode" \
  --statistic Sum \
  --period 86400 \
  --threshold 1000 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1
```

### 시간당 토큰 사용량 경보

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "ClaudeCode-HighTokenUsage" \
  --alarm-description "시간당 토큰 100만 초과 시 알림" \
  --metric-name "claude_code.token.usage" \
  --namespace "ClaudeCode" \
  --statistic Sum \
  --period 3600 \
  --threshold 1000000 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1
```

---

## AWS 조직 제약 대응

- OTEL Collector는 **단일 계정 내 ECS**로 동작 — 조직 기능 불필요
- 멤버 계정의 Claude Code는 ALB 엔드포인트로 직접 전송
- ALB를 퍼블릭 노출 시 **WAF IP 화이트리스트** 또는 **VPN 접근**으로 보안 유지
- 멀티 계정 시: 각 멤버 계정 VPC에서 중앙 ALB로 VPC 피어링 또는 PrivateLink 구성

---

## 부가 설정

### 컬렉터 자동 확장 조정

기본 설정:
- 최소 태스크: 1
- 최대 태스크: 4
- CPU 타겟: 70%
- 메모리 타겟: 80%

### 로그 보존 기간

CloudWatch Logs 보존 기간을 조정하여 비용 관리:

```bash
aws logs put-retention-policy \
  --log-group-name /aws/claude-code/metrics \
  --retention-in-days 90
```

### Security Group 규칙

ALB Security Group에 허용할 소스 IP 범위를 제한:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxx \
  --protocol tcp \
  --port 4318 \
  --cidr 10.0.0.0/8
```

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|------|------|------|
| 스택 배포 실패 | 서브넷 가용 영역 중복 | 서로 다른 AZ의 서브넷 지정 |
| curl 타임아웃 | Security Group 인바운드 미설정 | 포트 4318 허용 |
| CloudWatch 메트릭 없음 | IAM 권한 부족 | ECS Task Role에 `cloudwatch:PutMetricData` 확인 |
| ECS 태스크 실패 | 이미지 풀 실패 | NAT Gateway 또는 VPC 엔드포인트 확인 |
