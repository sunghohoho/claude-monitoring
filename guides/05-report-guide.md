# 05. 분석 및 보고서 가이드

실시간 모니터링 외에 히스토리 분석을 위한 데이터 레이크 파이프라인을 배포합니다. CloudWatch Logs → Kinesis Firehose → S3 → Athena SQL 쿼리로 장기 데이터 분석 및 보고서를 생성합니다.

---

## 사전 요구사항

| 항목 | 요구사항 |
|------|----------|
| 대시보드 스택 | 04-dashboard에서 배포 완료 |
| CloudWatch Logs | `/aws/claude-code/metrics` 로그 그룹에 데이터 수신 중 |
| IAM 권한 | Kinesis Firehose, S3, Glue, Athena 생성 권한 |

---

## 분석 아키텍처

```
CloudWatch Logs → Kinesis Data Firehose → S3 (Parquet) → Athena SQL
                                                ↓
                                          Glacier (90일 후)
```

| 구성 요소 | 역할 |
|-----------|------|
| Kinesis Data Firehose | CloudWatch Logs를 S3로 실시간 스트리밍 |
| S3 버킷 | Parquet 형식으로 히스토리 메트릭 저장 |
| Athena 워크그룹 | 전용 SQL 쿼리 환경 |
| 사전 빌드 쿼리 | 10개의 즉시 사용 가능한 분석 쿼리 |

---

## 단계별 배포 방법

### 1. 분석 파이프라인 스택 배포

```bash
cd guidance-for-claude-code-with-amazon-bedrock/deployment/infrastructure

aws cloudformation deploy \
  --template-file analytics-pipeline.yaml \
  --stack-name claude-code-analytics \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    DashboardStackName=claude-code-dashboard
```

### 2. 배포 완료 확인

```bash
aws cloudformation describe-stacks \
  --stack-name claude-code-analytics \
  --query 'Stacks[0].StackStatus' --output text
```

### 3. Athena 콘솔 URL 조회

```bash
aws cloudformation describe-stacks \
  --stack-name claude-code-analytics \
  --query 'Stacks[0].Outputs[?OutputKey==`AthenaConsoleUrl`].OutputValue' \
  --output text
```

---

## 사전 빌드된 분석 쿼리

Athena 콘솔에서 워크그룹 `claude-code-analytics-workgroup` 선택 → **Saved queries** 탭.

| 쿼리 | 용도 |
|------|------|
| 토큰 사용량 상위 사용자 | 파워 유저 및 소비 패턴 식별 |
| 모델/유형별 토큰 사용량 | 모델 선택 및 비용 최적화 |
| 사용자 활동 패턴 | 피크 사용 시간 분석 (용량 계획) |
| 조직별 사용량 | 조직 청구 및 차지백 |
| 이메일 도메인별 사용량 | 팀/부서 전체 사용량 분석 |
| TPM 및 RPM 분석 | 속도 제한 및 API 사용 패턴 |
| 사용자 세션 분석 | 사용자 행동 및 세션 패턴 |
| 상세 비용 귀속 | 정밀 청구 및 비용 관리 |
| 피크 사용량 분석 | 서비스 중단 방지 사전 모니터링 |
| ID 제공자별 사용량 | 인증 방법별 사용량 비교 |

---

## 주요 쿼리 예제

### 상위 사용자 (최근 7일)

```sql
WITH user_totals AS (
    SELECT
        user_id,
        user_email,
        organization_id,
        SUM(token_usage) as total_tokens,
        COUNT(DISTINCT session_id) as session_count,
        COUNT(DISTINCT CAST(from_unixtime(timestamp/1000) AS DATE)) as active_days
    FROM "claude-code-analytics_analytics".metrics
    WHERE year = CAST(YEAR(CURRENT_DATE) AS VARCHAR)
        AND month IN (LPAD(CAST(MONTH(CURRENT_DATE) AS VARCHAR), 2, '0'),
                      LPAD(CAST(MONTH(CURRENT_DATE - INTERVAL '1' MONTH) AS VARCHAR), 2, '0'))
        AND from_unixtime(timestamp/1000) >= CURRENT_TIMESTAMP - INTERVAL '7' DAY
    GROUP BY user_id, user_email, organization_id
)
SELECT
    user_email,
    organization_id,
    SUBSTR(user_id, 1, 8) || '...' as user_id_short,
    total_tokens,
    session_count,
    active_days,
    ROUND(total_tokens * 0.000015, 2) as estimated_cost_usd
FROM user_totals
ORDER BY total_tokens DESC
LIMIT 10;
```

### 조직별 토큰 사용량 (최근 30일)

```sql
SELECT
    organization_id,
    COUNT(DISTINCT user_id) as unique_users,
    COUNT(DISTINCT user_email) as unique_emails,
    COUNT(DISTINCT session_id) as total_sessions,
    SUM(CASE WHEN type = 'input' THEN token_usage ELSE 0 END) as input_tokens,
    SUM(CASE WHEN type = 'output' THEN token_usage ELSE 0 END) as output_tokens,
    SUM(token_usage) as total_tokens,
    ROUND(SUM(token_usage) * 0.000015, 2) as estimated_cost_usd
FROM "claude-code-analytics_analytics".metrics
WHERE year = CAST(YEAR(CURRENT_DATE) AS VARCHAR)
    AND from_unixtime(timestamp/1000) >= CURRENT_TIMESTAMP - INTERVAL '30' DAY
GROUP BY organization_id
ORDER BY total_tokens DESC;
```

### 시간대별 사용 패턴

```sql
SELECT
    HOUR(from_unixtime(timestamp/1000)) as hour_of_day,
    COUNT(DISTINCT user_id) as active_users,
    SUM(token_usage) as tokens,
    COUNT(DISTINCT session_id) as sessions
FROM "claude-code-analytics_analytics".metrics
WHERE from_unixtime(timestamp/1000) >= CURRENT_TIMESTAMP - INTERVAL '7' DAY
GROUP BY HOUR(from_unixtime(timestamp/1000))
ORDER BY hour_of_day;
```

---

## 데이터 보존 및 비용 최적화

| 계층 | 보존 기간 | 용도 |
|------|-----------|------|
| S3 Standard | 90일 (구성 가능) | 활성 쿼리 대상 |
| S3 Glacier | 90일 이후 자동 전환 | 장기 보관 |
| Athena 쿼리 결과 | 7일 후 자동 삭제 | 임시 결과 |

**비용 최적화 포인트:**
- Parquet 컬럼형 형식으로 스캔 데이터량 최소화
- 파티션 프로젝션으로 Glue 크롤러 비용 제거
- Athena 워크그룹에 쿼리당 스캔 제한 설정 가능

---

## 데이터 내보내기

### CLI로 쿼리 실행

```bash
aws athena start-query-execution \
  --query-string "SELECT * FROM metrics WHERE from_unixtime(timestamp/1000) >= CURRENT_TIMESTAMP - INTERVAL '7' DAY LIMIT 1000" \
  --result-configuration OutputLocation=s3://your-results-bucket/ \
  --work-group claude-code-analytics-workgroup
```

### 결과 다운로드

```bash
QUERY_ID=$(aws athena start-query-execution ... --output text)
aws athena get-query-results --query-execution-id $QUERY_ID
```

---

## 고급 분석 활용

### ROI 측정

비교 항목:
- 절약된 개발자 시간 (`active_time.total` 메트릭)
- 코드 생산성 향상 (`lines_of_code.count`, `commit.count`)
- Claude Code 사용 비용 (`cost.usage`)

### 사용량 예측

히스토리 데이터 기반:
- 향후 토큰 소비 예측
- 예산 계획 수립
- 계절적 사용 패턴 식별

### 비즈니스 보고서 자동화

- Athena 쿼리 + Lambda + SES로 주간/월간 이메일 보고서
- QuickSight 연동으로 BI 대시보드 구성
- S3 데이터를 외부 분석 도구(Tableau, Looker)로 연결

---

## AWS 조직 제약 대응

- Kinesis Firehose, S3, Athena 모두 **단일 계정 서비스** — 조직 기능 불필요
- 멤버 계정 데이터는 중앙 OTEL Collector를 통해 이미 수집되므로 추가 구성 불필요
- cross-account S3 접근이 필요하면 버킷 정책에 멤버 계정 ARN 추가

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|------|------|------|
| Athena 쿼리 0건 | 데이터 미도착 | Firehose 배달 상태 확인, S3 버킷에 파일 존재 확인 |
| 파티션 미인식 | year/month 파티션 미생성 | `MSCK REPAIR TABLE` 실행 |
| 쿼리 비용 초과 | 파티션 미사용 | WHERE 절에 year/month 조건 추가 |
| Firehose 실패 | IAM 권한 | Firehose 역할에 S3 PutObject 권한 확인 |
