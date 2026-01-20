# docs/architecture.md
# Trade Data Pipeline Architecture

## Overview
Real-time trade data processing pipeline using Google Cloud Platform and Snowflake.

## Architecture Diagram
![Architecture Diagram](Sample-Code-DB.png)

## Components

### 1. Data Generation
- **Trade Generator**: Python service that generates realistic trade data
- **Features**: Configurable rate, data quality issues, batch generation
- **Output**: JSON messages published to Pub/Sub

### 2. Message Queue
- **Google Pub/Sub**: Fully managed message queue
- **Features**: Exactly-once delivery, dead-letter topics, schema validation
- **Configuration**: 7-day retention, ordering enabled

### 3. Stream Processing
- **Apache Beam/Dataflow**: Serverless stream processing
- **Processing**:
  - JSON parsing and validation
  - Business rule enforcement
  - Data enrichment
  - Error handling
- **Output**: Valid/Rejected/Expired trades to Snowflake

### 4. Data Warehouse
- **Snowflake**: Cloud data platform
- **Schemas**:
  - RAW: Raw staging data
  - PROCESSED: Validated and enriched data
  - ANALYTICS: Aggregated views
  - AUDIT: Rejected data and audit trails
- **Features**: Time travel, zero-copy cloning, Snowpipe auto-ingestion

### 5. Orchestration
- **Apache Airflow/Cloud Composer**: Workflow orchestration
- **DAGs**: Daily processing, data quality checks, reporting
- **Monitoring**: Pipeline health, alerting, retry logic

### 6. Monitoring & Alerting
- **Cloud Monitoring**: Metrics and dashboards
- **Prometheus**: Custom metrics collection
- **Alerting**: Email, Slack notifications
- **Logging**: Structured logging with Cloud Logging

## Data Flow

1. **Ingestion**: Trades published to Pub/Sub → Dataflow subscription
2. **Processing**: Dataflow validates/enriches → Writes to Snowflake
3. **Transformation**: Snowflake tasks process staging data
4. **Analytics**: Materialized views for dashboards
5. **Monitoring**: Health checks and alerting
6. **Orchestration**: Scheduled DAGs manage the workflow

## Business Rules

### Validation Rules
1. **Version Control**: Reject trades with lower version than existing
2. **Maturity Date**: Reject trades with past maturity dates
3. **Data Quality**: Validate all required fields and data types
4. **Business Logic**: Check counterparty approval status

### Processing Rules
1. **Valid Trades**: Store in PROCESSED.VALID_TRADES with SCD Type 2
2. **Rejected Trades**: Store in AUDIT.REJECTED_TRADES with reasons
3. **Expired Trades**: Mark as expired in PROCESSED.EXPIRED_TRADES
4. **Audit Trail**: Log all changes in AUDIT.TRADE_AUDIT_TRAIL

## Security

### Data Protection
- **Encryption**: All data encrypted at rest and in transit
- **Masking**: Dynamic data masking in Snowflake
- **Access Control**: Role-based access with least privilege

### Network Security
- **Private VPC**: Isolated network for GCP resources
- **Private IP**: Dataflow workers use private IPs
- **Network Policies**: Snowflake IP whitelisting

### Secrets Management
- **Secret Manager**: Store Snowflake credentials
- **IAM**: Service accounts with minimal permissions
- **Rotation**: Automated credential rotation

## Scalability

### Horizontal Scaling
- **Dataflow**: Auto-scaling based on Pub/Sub backlog
- **Snowflake**: Multi-cluster warehouses
- **Pub/Sub**: Automatic partitioning

### Performance Optimization
- **Dataflow**: Streaming Engine, shuffle service
- **Snowflake**: Clustering keys, materialized views
- **Caching**: Redis for frequently accessed data

## Monitoring & Operations

### Key Metrics
- **Throughput**: Trades processed per second
- **Latency**: End-to-end processing time
- **Data Freshness**: Age of latest data
- **Error Rate**: Percentage of failed/rejected trades

### Alerting
- **Critical**: Pipeline failure, data corruption
- **Warning**: High backlog, slow processing
- **Info**: Daily reports, successful runs

### Dashboards
- **Operational**: Pipeline health, resource usage
- **Business**: Trade volumes, risk exposure
- **Compliance**: Audit trails, data quality

## Disaster Recovery

### Backup Strategy
- **Snowflake**: Time travel (90 days), failover groups
- **GCS**: Versioning, cross-region replication
- **Terraform**: Infrastructure as code with state backup

### Recovery Procedures
1. **Data Recovery**: Time travel or clone from backup
2. **Pipeline Recovery**: Restart from checkpoint
3. **Infrastructure Recovery**: Terraform apply from state

## Cost Optimization

### Snowflake
- **Warehouse Sizing**: Right-size based on workload
- **Auto-suspend**: Suspend when idle
- **Resource Monitors**: Credit usage alerts

### GCP
- **Committed Use**: Discounts for sustained usage
- **Dataflow**: Optimize worker configuration
- **Storage**: Lifecycle policies for old data

## Deployment

### Environments
- **Development**: Rapid iteration, minimal cost
- **Staging**: Full scale testing
- **Production**: High availability, monitoring

### CI/CD
- **GitHub Actions**: Automated testing and deployment
- **Terraform**: Infrastructure deployment
- **Container Registry**: Docker image management

## Maintenance

### Regular Tasks
- **Data Cleanup**: Archive old data
- **Performance Tuning**: Optimize queries
- **Security Updates**: Rotate credentials, apply patches

### Monitoring
- **Daily**: Check pipeline health, review alerts
- **Weekly**: Performance analysis, capacity planning
- **Monthly**: Cost review, security audit
