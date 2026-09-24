locals {
  # Trailing slash stripped: browsers send the origin without one, so S3's
  # CORS comparison would reject uploads, and PUBLIC_API_URL would read //api.
  public_app_url = var.public_app_url != "" ? trimsuffix(var.public_app_url, "/") : "http://${aws_lb.this.dns_name}"

  # The backend reads DATABASE_URL_OVERRIDE verbatim, so anything that needs
  # percent-encoding in the password breaks the DSN. Generating without special
  # characters avoids the encoding step entirely.
  database_url = "postgresql+asyncpg://geolens:${random_password.db.result}@${aws_db_instance.this.address}:5432/geolens"
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "jwt" {
  length  = 64
  special = false
}

# GeoLens holds passwords to three character classes, and a plain
# alphanumeric draw skips a class often enough to matter (about 1.5% of
# 24-character draws have no digit), so each class is forced.
resource "random_password" "admin" {
  length      = 24
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

# ponytail: the RDS master user is both the migration and application login.
# Keep this stack on one dedicated instance per organization; the current
# recipe does not run GeoLens' canonical managed-Postgres role reconciler.
resource "aws_db_subnet_group" "this" {
  name_prefix = "${var.name}-"
  subnet_ids  = aws_subnet.private[*].id
}

# ponytail: single-AZ (multi_az = false), so patching or an AZ outage takes the
# database offline. Multi-AZ adds a standby for about twice the instance cost.
resource "aws_db_instance" "this" {
  identifier_prefix = "${var.name}-"

  # PostGIS, pgvector, pg_trgm and unaccent all ship with RDS PostgreSQL 17.
  # Naming the major version alone lets RDS pick the current minor.
  engine         = "postgres"
  engine_version = "17"
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "geolens"
  username = "geolens"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.data.id]
  publicly_accessible    = false
  multi_az               = false
  copy_tags_to_snapshot  = var.pilot_profile

  backup_retention_period = var.backup_retention_days
  apply_immediately       = true
  skip_final_snapshot     = var.skip_final_snapshot
  deletion_protection     = var.deletion_protection

  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  lifecycle {
    ignore_changes = [final_snapshot_identifier, engine_version]
  }
}

resource "aws_s3_bucket" "this" {
  bucket_prefix = "${var.name}-"
  force_destroy = var.s3_force_destroy
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The same TLS-only rule the pilot README asks of the state bucket. The
# app, titiler and the presigned URLs browsers upload to all use HTTPS.
resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Uploads over 100 MB go straight from the browser to S3 as a presigned
# multipart upload, so the browser origin needs CORS and the ETag of each part.
resource "aws_s3_bucket_cors_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  cors_rule {
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_origins = [local.public_app_url]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_versioning" "this" {
  count = var.s3_versioning_enabled ? 1 : 0

  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Every bucket aborts abandoned multipart uploads, the backstop clouds/aws.md
# asks for.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  dynamic "rule" {
    for_each = var.s3_versioning_enabled ? [1] : []

    content {
      id     = "expire-noncurrent-versions"
      status = "Enabled"

      filter {}

      noncurrent_version_expiration {
        noncurrent_days = var.s3_noncurrent_version_expiration_days
      }
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# Stacks from when only a versioned bucket had a lifecycle hold it at [0].
moved {
  from = aws_s3_bucket_lifecycle_configuration.this[0]
  to   = aws_s3_bucket_lifecycle_configuration.this
}

resource "aws_elasticache_subnet_group" "this" {
  count = var.cache_enabled ? 1 : 0

  name       = "${var.name}-cache"
  subnet_ids = aws_subnet.private[*].id
}

# ponytail: one node, no replica, no TLS, so REDIS_URL is a plain redis://
# string. Turn on transit encryption and switch to rediss:// when the VPC is
# shared or the cache holds anything worth intercepting. The replication group
# resource is what carries Valkey; aws_elasticache_cluster still only speaks
# redis and memcached.
resource "aws_elasticache_replication_group" "this" {
  count = var.cache_enabled ? 1 : 0

  replication_group_id = "${var.name}-cache"
  description          = "GeoLens cache"

  engine               = "valkey"
  engine_version       = "8.1"
  node_type            = "cache.t4g.micro"
  num_cache_clusters   = 1
  parameter_group_name = "default.valkey8"
  port                 = 6379

  automatic_failover_enabled = false
  transit_encryption_enabled = false

  subnet_group_name  = aws_elasticache_subnet_group.this[0].name
  security_group_ids = [aws_security_group.data.id]

  apply_immediately = true
}

# A dedicated key for stored SSO secrets, so a JWT rotation does not strand
# them. The app keeps the JWT-derived key as its last fallback, so old
# ciphertexts stay readable; replacing this key strands what it wrote.
resource "random_bytes" "secret_encryption_key" {
  length = 32
}

# One secret holds every credential the tasks need. ECS pulls individual keys
# out of the JSON with the `arn:key::` valueFrom suffix. name_prefix matters:
# Secrets Manager keeps deleted names reserved for a recovery window, so a
# fixed name blocks a re-apply after a destroy.
resource "aws_secretsmanager_secret" "app" {
  name_prefix = "${var.name}/app-"
  description = "GeoLens application credentials"
  # Stated explicitly because the README promises it; the provider default
  # is 30 days.
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id

  secret_string = jsonencode({
    DATABASE_URL_OVERRIDE  = local.database_url
    JWT_SECRET_KEY         = random_password.jwt.result
    GEOLENS_ADMIN_USERNAME = var.admin_username
    GEOLENS_ADMIN_PASSWORD = var.admin_password != "" ? var.admin_password : random_password.admin.result
    # A Fernet key: url-safe base64 of the 32 bytes.
    SECRET_ENCRYPTION_KEY = replace(replace(random_bytes.secret_encryption_key.base64, "+", "-"), "/", "_")
  })
}
