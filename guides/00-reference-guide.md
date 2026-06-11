# 00. 참조 리소스 목록

각 Phase에서 사용하는 GitHub 저장소, CloudFormation 템플릿, 주요 AWS 리소스를 한눈에 정리합니다.

---

## GitHub 저장소

| 저장소 | 용도 | 클론 명령 |
|--------|------|-----------|
| [guidance-for-claude-code-with-amazon-bedrock](https://github.com/aws-solutions-library-samples/guidance-for-claude-code-with-amazon-bedrock) | 공식 AWS 솔루션 — 인프라 템플릿 전체 | `git clone https://github.com/aws-solutions-library-samples/guidance-for-claude-code-with-amazon-bedrock.git` |

### 저장소 구조 (deployment/infrastructure/)

```
guidance-for-claude-code-with-amazon-bedrock/
└── deployment/
    └── infrastructure/
        ├── otel-collector.yaml          ← Phase 3: OTEL Collector (ECS + ALB)
        ├── claude-code-dashboard.yaml   ← Phase 4: CloudWatch 대시보드
        └── analytics-pipeline.yaml      ← Phase 5: 분석 파이프라인 (Firehose + S3 + Athena)
```

---

## CloudFormation 템플릿 상세

### 1. otel-collector.yaml

| 항목 | 내용 |
|------|------|
| **사용 Phase** | 03 — 데이터 수집 파이프라인 |
| **스택 이름** | `claude-code-otel-collector` |
| **Capabilities** | `CAPABILITY_IAM` |

**파라미터:**

| 파라미터 | 타입 | 설명 | 필수 |
|---------|------|------|------|
| VpcId | String | VPC ID | ✅ |
| SubnetIds | CommaDelimitedList | 서브넷 ID (최소 2개, 서로 다른 AZ) | ✅ |
| EnableAnalytics | String | 분석 파이프라인 연동 (true/false) | 선택 |

**생성 리소스:**

| 리소스 | 타입 | 역할 |
|--------|------|------|
| ECS Cluster | `AWS::ECS::Cluster` | Fargate 클러스터 |
| ECS Service | `AWS::ECS::Service` | OTEL Collector 태스크 실행 |
| Task Definition | `AWS::ECS::TaskDefinition` | Collector 컨테이너 정의 |
| ALB | `AWS::ElasticLoadBalancingV2::LoadBalancer` | OTLP 수신 엔드포인트 |
| Target Group | `AWS::ElasticLoadBalancingV2::TargetGroup` | ECS 태스크 라우팅 |
| Security Group | `AWS::EC2::SecurityGroup` | ALB 인바운드 (4318 포트) |
| IAM Role | `AWS::IAM::Role` | ECS Task Role (CloudWatch PutMetricData) |
| CloudWatch Log Group | `AWS::Logs::LogGroup` | `/aws/claude-code/metrics` |
| Auto Scaling | `AWS::ApplicationAutoScaling::*` | CPU/메모리 기반 스케일링 |

**출력:**

| Output Key | 설명 |
|-----------|------|
| CollectorEndpoint | ALB 엔드포인트 URL (클라이언트 OTEL_EXPORTER_OTLP_ENDPOINT에 사용) |

---

### 2. claude-code-dashboard.yaml

| 항목 | 내용 |
|------|------|
| **사용 Phase** | 04 — 사용량 대시보드 |
| **스택 이름** | `claude-code-dashboard` |
| **Capabilities** | `CAPABILITY_NAMED_IAM` |
| **패키징 필요** | ✅ (`aws cloudformation package` 선행) |

**파라미터:**

| 파라미터 | 타입 | 설명 | 기본값 |
|---------|------|------|--------|
| MetricsRegion | String | 메트릭 수집 리전 | us-west-2 |

**생성 리소스:**

| 리소스 | 타입 | 역할 |
|--------|------|------|
| CloudWatch Dashboard | `AWS::CloudWatch::Dashboard` | 시각화 대시보드 |
| Lambda Function(s) | `AWS::Lambda::Function` | 커스텀 위젯 데이터 처리 |
| IAM Role | `AWS::IAM::Role` | Lambda 실행 역할 |

**출력:**

| Output Key | 설명 |
|-----------|------|
| DashboardURL | CloudWatch 대시보드 콘솔 URL |

**배포 명령:**

```bash
# 1. S3 버킷 생성
aws s3 mb s3://claude-code-cfn-artifacts-$(aws sts get-caller-identity --query Account --output text)

# 2. 패키징
aws cloudformation package \
  --template-file claude-code-dashboard.yaml \
  --s3-bucket claude-code-cfn-artifacts-ACCOUNT_ID \
  --output-template-file packaged-claude-code-dashboard.yaml

# 3. 배포
aws cloudformation deploy \
  --template-file packaged-claude-code-dashboard.yaml \
  --stack-name claude-code-dashboard \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides MetricsRegion=us-east-1
```

---

### 3. analytics-pipeline.yaml

| 항목 | 내용 |
|------|------|
| **사용 Phase** | 05 — 분석 및 보고서 |
| **스택 이름** | `claude-code-analytics` |
| **Capabilities** | `CAPABILITY_IAM` |

**파라미터:**

| 파라미터 | 타입 | 설명 | 필수 |
|---------|------|------|------|
| DashboardStackName | String | 대시보드 스택 이름 (크로스 스택 참조) | ✅ |

**생성 리소스:**

| 리소스 | 타입 | 역할 |
|--------|------|------|
| Kinesis Data Firehose | `AWS::KinesisFirehose::DeliveryStream` | CloudWatch Logs → S3 스트리밍 |
| S3 Bucket | `AWS::S3::Bucket` | 히스토리 메트릭 저장 (Parquet) |
| S3 Lifecycle | `AWS::S3::Bucket` 설정 | 90일 후 Glacier 전환 |
| Glue Database | `AWS::Glue::Database` | Athena 카탈로그 |
| Glue Table | `AWS::Glue::Table` | 메트릭 스키마 정의 (파티션 프로젝션) |
| Athena Workgroup | `AWS::Athena::WorkGroup` | 전용 쿼리 환경 |
| Athena Named Queries | `AWS::Athena::NamedQuery` | 10개 사전 빌드 쿼리 |

**출력:**

| Output Key | 설명 |
|-----------|------|
| AthenaConsoleUrl | Athena 쿼리 콘솔 URL |
| S3BucketName | 분석 데이터 S3 버킷 이름 |

---

## 배포 순서 및 의존성

```
otel-collector.yaml  ──→  claude-code-dashboard.yaml  ──→  analytics-pipeline.yaml
     (독립)                    (독립, 패키징 필요)            (DashboardStackName 참조)
```

- `otel-collector`와 `dashboard`는 서로 독립적으로 배포 가능
- `analytics-pipeline`은 `dashboard` 스택을 참조하므로 반드시 이후에 배포

---

## 프로덕션 배포 참조

> AWS 공식 솔루션: **Guidance for Claude Code with Amazon Bedrock**
> 
> 모니터링, 분석, 할당량 관리가 포함된 완전한 infrastructure-as-code 솔루션을 제공합니다.
> 프로덕션 환경에서는 이 솔루션의 전체 배포를 권장합니다.

---

## 추가 도구 참조

| 도구 | 용도 | 비고 |
|------|------|------|
| `ccwb init` | 사이드카 모드 빠른 시작 | Go 1.23+ 필요, 서버 인프라 불필요 |
| CloudWatch cross-account observability | 멤버 계정 메트릭 중앙 수집 | All Features 없이 사용 가능 |
| Jellyfish (AWS Marketplace) | 개발자 생산성 분석 | OTEL 메트릭 연동, DORA 메트릭 추적 |

---

## 환경변수 전체 목록 (클라이언트 측)

| 변수 | 값 | 설명 |
|------|-----|------|
| `CLAUDE_CODE_ENABLE_TELEMETRY` | `1` | 텔레메트리 활성화 |
| `OTEL_METRICS_EXPORTER` | `otlp` | 메트릭 익스포터 |
| `OTEL_LOGS_EXPORTER` | `otlp` | 로그 익스포터 |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | OTLP 프로토콜 |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://ALB_ENDPOINT` | Collector 엔드포인트 |
| `OTEL_METRIC_EXPORT_INTERVAL` | `60000` | 메트릭 내보내기 간격 (ms) |
| `OTEL_LOGS_EXPORT_INTERVAL` | `30000` | 로그 내보내기 간격 (ms) |
| `OTEL_RESOURCE_ATTRIBUTES` | `key=value,...` | 사용자/팀/부서 귀속 속성 |
