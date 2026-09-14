# CloudWatch alarms → SNS email

Hand-applied. Nothing here is created by Terraform or `deploy.sh`. The three JVM services
(Identity, oneOps backend, MobiStack backend) export Micrometer meters to namespace **`Prabhix`**
when `CLOUDWATCH_METRICS=true` (or Spring profile `cloudwatch`). Common tag `application` is
`spring.application.name`:

| Service | `application` tag | Image / container |
| --- | --- | --- |
| Identity | `prabhix-identity` | `identity` |
| oneOps API | `prabhix-platform` | `backend` |
| MobiStack API | `fixflow-backend` | `mobistack-backend` |

Instance role needs `cloudwatch:PutMetricData` on `*` (PutMetricData cannot be resource-scoped).
RDS connection alarms use the AWS/RDS namespace and need no application change.

## 1. SNS topic and email subscription

```bash
TOPIC_ARN=$(aws sns create-topic --region ap-south-1 --name prabhix-ops-alarms \
  --query TopicArn --output text)

aws sns subscribe --region ap-south-1 --topic-arn "$TOPIC_ARN" \
  --protocol email --notification-endpoint ops@prabhixtechnologies.com
```

Confirm the subscription from the mailbox before alarms can deliver.

## 2. PutMetricAlarm (repeat per service)

Replace `APPLICATION` with each row above. `Namespace` is always `Prabhix` except RDS.

Micrometer publishes timers as a count metric plus a statistic set. Exact published names can be
confirmed with:

```bash
aws cloudwatch list-metrics --region ap-south-1 --namespace Prabhix
```

### HTTP 5xx

```bash
aws cloudwatch put-metric-alarm --region ap-south-1 --cli-input-json file://- <<EOF
{
  "AlarmName": "prabhix-${APPLICATION}-5xx",
  "AlarmDescription": "5xx responses from ${APPLICATION}",
  "Namespace": "Prabhix",
  "MetricName": "http.server.requests.count",
  "Dimensions": [
    {"Name": "application", "Value": "${APPLICATION}"},
    {"Name": "outcome", "Value": "SERVER_ERROR"}
  ],
  "Statistic": "Sum",
  "Period": 300,
  "EvaluationPeriods": 1,
  "Threshold": 5,
  "ComparisonOperator": "GreaterThanOrEqualToThreshold",
  "TreatMissingData": "notBreaching",
  "AlarmActions": ["${TOPIC_ARN}"]
}
EOF
```

If `outcome` is not present on the published metric, alarm on `status=500` (and 502/503) instead.

### p99 latency

```bash
aws cloudwatch put-metric-alarm --region ap-south-1 --cli-input-json file://- <<EOF
{
  "AlarmName": "prabhix-${APPLICATION}-p99",
  "AlarmDescription": "p99 request latency above 2s for ${APPLICATION}",
  "Namespace": "Prabhix",
  "MetricName": "http.server.requests",
  "Dimensions": [
    {"Name": "application", "Value": "${APPLICATION}"}
  ],
  "ExtendedStatistic": "p99",
  "Period": 300,
  "EvaluationPeriods": 2,
  "Threshold": 2.0,
  "ComparisonOperator": "GreaterThanThreshold",
  "TreatMissingData": "notBreaching",
  "AlarmActions": ["${TOPIC_ARN}"]
}
EOF
```

### Mail outbox backlog (oneOps / `prabhix-platform` only)

Matches the Prometheus rule `prabhix_mail_outbox_pending > 500`.

```bash
aws cloudwatch put-metric-alarm --region ap-south-1 --cli-input-json file://- <<EOF
{
  "AlarmName": "prabhix-platform-outbox-backlog",
  "AlarmDescription": "Pending mail outbox rows exceed 500",
  "Namespace": "Prabhix",
  "MetricName": "prabhix.mail.outbox.pending",
  "Dimensions": [
    {"Name": "application", "Value": "prabhix-platform"}
  ],
  "Statistic": "Maximum",
  "Period": 300,
  "EvaluationPeriods": 2,
  "Threshold": 500,
  "ComparisonOperator": "GreaterThanThreshold",
  "TreatMissingData": "notBreaching",
  "AlarmActions": ["${TOPIC_ARN}"]
}
EOF
```

### JVM heap

```bash
aws cloudwatch put-metric-alarm --region ap-south-1 --cli-input-json file://- <<EOF
{
  "AlarmName": "prabhix-${APPLICATION}-jvm-heap",
  "AlarmDescription": "Used heap above 85% of max for ${APPLICATION}",
  "Metrics": [
    {
      "Id": "used",
      "MetricStat": {
        "Metric": {
          "Namespace": "Prabhix",
          "MetricName": "jvm.memory.used",
          "Dimensions": [
            {"Name": "application", "Value": "${APPLICATION}"},
            {"Name": "area", "Value": "heap"}
          ]
        },
        "Period": 300,
        "Stat": "Average"
      }
    },
    {
      "Id": "max",
      "MetricStat": {
        "Metric": {
          "Namespace": "Prabhix",
          "MetricName": "jvm.memory.max",
          "Dimensions": [
            {"Name": "application", "Value": "${APPLICATION}"},
            {"Name": "area", "Value": "heap"}
          ]
        },
        "Period": 300,
        "Stat": "Average"
      }
    },
    {
      "Id": "ratio",
      "Expression": "used / max",
      "ReturnData": true
    }
  ],
  "EvaluationPeriods": 2,
  "Threshold": 0.85,
  "ComparisonOperator": "GreaterThanThreshold",
  "TreatMissingData": "notBreaching",
  "AlarmActions": ["${TOPIC_ARN}"]
}
EOF
```

### Deny-list Redis outage

Lookups fail open (a Redis outage must not lock every user out). This alarm is the
compensation: any increment means revocations are not being applied.

```bash
aws cloudwatch put-metric-alarm --region ap-south-1 --cli-input-json file://- <<EOF
{
  "AlarmName": "prabhix-deny-list-redis-unavailable",
  "AlarmDescription": "Identity/oneOps deny-list could not reach Redis; lookups fail open",
  "Namespace": "Prabhix",
  "MetricName": "prabhix.identity.deny_list.redis_unavailable",
  "Statistic": "Sum",
  "Period": 300,
  "EvaluationPeriods": 1,
  "Threshold": 1,
  "ComparisonOperator": "GreaterThanOrEqualToThreshold",
  "TreatMissingData": "notBreaching",
  "AlarmActions": ["${TOPIC_ARN}"]
}
EOF
```

### RDS connections

The databases share one RDS instance. Alarm on AWS's own metric, not Micrometer:

```bash
aws rds describe-db-instances --region ap-south-1 \
  --query 'DBInstances[].DBInstanceIdentifier' --output text

aws cloudwatch put-metric-alarm --region ap-south-1 --cli-input-json file://- <<EOF
{
  "AlarmName": "prabhix-rds-connections",
  "AlarmDescription": "RDS DatabaseConnections above 80% of the instance max",
  "Namespace": "AWS/RDS",
  "MetricName": "DatabaseConnections",
  "Dimensions": [
    {"Name": "DBInstanceIdentifier", "Value": "REPLACE_WITH_INSTANCE_ID"}
  ],
  "Statistic": "Average",
  "Period": 300,
  "EvaluationPeriods": 2,
  "Threshold": 80,
  "ComparisonOperator": "GreaterThanThreshold",
  "TreatMissingData": "notBreaching",
  "AlarmActions": ["${TOPIC_ARN}"]
}
EOF
```

Set `Threshold` from the instance class connection ceiling (for example ~80% of
`max_connections` on the parameter group), not the number above.

## 3. Enable export on the box

In `/prabhix/prod/env` (Parameter Store; `ENV_SOURCE=ssm`):

```
CLOUDWATCH_METRICS=true
```

Then deploy. Leave it unset or `false` locally — tests must not open a CloudWatch client.
