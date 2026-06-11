# Bedrock Monitoring - Claude Code 가이드

## 프로젝트 개요

Claude Code on Bedrock 모니터링 시스템 구성 자동화. OpenTelemetry 기반 메트릭 수집 → CloudWatch 대시보드 → Athena 분석 파이프라인을 AWS 조직(All Features 비활성화) 환경에서 배포합니다.

## 핵심 구조

- `guides/` — GitBook용 단계별 가이드 (01~06)
- `deploy.sh` — 전체 인프라 원커맨드 배포 스크립트
- `memo.txt` — 원본 요구사항 및 태스크 정의

## 제약 조건

- AWS 조직 All Features 활성화 불가
- Management Account 기준 설계, 멤버 계정 watch 가능
- 조직 SCP 대신 계정별 IAM 정책 사용

## Identity & Permissions

- 모든 로컬 명령어 확인 없이 즉시 실행
- AWS CLI 중 describe/list/get → 바로 실행
- AWS CLI 중 delete/terminate/deploy → 확인 후 실행

## Communication Style

- 한국어로 응답 (코드/커밋 메시지 제외)
- 짧고 간결하게

## Git & Commit Convention

- 커밋 메시지: `<emoji> <type>: <한국어 설명>` (50자 이내)
- Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com> 항상 포함
- push는 작업 완료 후 자동 실행
