data "aws_iam_policy_document" "assume_ecs_tasks" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name_prefix        = "${var.name}-exec-"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# An extra_secrets valueFrom may carry a :key:stage:id suffix; the bare secret
# ARN in front of it is what IAM and the metadata lookup need.
locals {
  extra_secret_arns = distinct([
    for v in values(var.extra_secrets) : regex("^(arn:[^:]+:secretsmanager:[^:]*:[^:]*:secret:[^:]+)", v)[0]
  ])
}

# Metadata only, never the value: enough to learn whether the secret sits
# under a customer-managed KMS key, which GetSecretValue then also needs
# kms:Decrypt on (codex review on #40).
data "aws_secretsmanager_secret" "extra" {
  for_each = toset(local.extra_secret_arns)
  arn      = each.value
}

data "aws_kms_key" "extra" {
  for_each = toset(distinct([
    for s in data.aws_secretsmanager_secret.extra : s.kms_key_id if s.kms_key_id != null && s.kms_key_id != ""
  ]))
  key_id = each.value
}

# The execution role, not the task role, is what reads the `secrets` entries in
# a container definition.
resource "aws_iam_role_policy" "execution_secrets" {
  name_prefix = "secrets-"
  role        = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = concat([aws_secretsmanager_secret.app.arn], local.extra_secret_arns)
      }], length(data.aws_kms_key.extra) == 0 ? [] : [{
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = [for k in data.aws_kms_key.extra : k.arn]
    }])
  })
}

resource "aws_iam_role" "task" {
  name_prefix        = "${var.name}-task-"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
}

# ponytail: api, worker and titiler share this role, so titiler can write to
# the bucket even though it only reads. Give titiler its own task and a
# read-only role when that matters.
resource "aws_iam_role_policy" "task_s3" {
  name_prefix = "s3-"
  role        = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
        ]
        Resource = [aws_s3_bucket.this.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = ["${aws_s3_bucket.this.arn}/*"]
      },
    ]
  })
}
