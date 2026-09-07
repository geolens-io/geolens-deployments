locals {
  api_image      = "ghcr.io/geolens-io/geolens-api:${var.geolens_version}"
  frontend_image = "ghcr.io/geolens-io/geolens-frontend:${var.geolens_version}"
  titiler_image  = "ghcr.io/developmentseed/titiler:${var.titiler_version}"

  # Shared by api, worker and the migrate task.
  backend_env = [
    { name = "ENVIRONMENT", value = "production" },
    { name = "LOG_JSON", value = "true" },
    { name = "PUBLIC_APP_URL", value = local.public_app_url },
    { name = "PUBLIC_API_URL", value = "${local.public_app_url}/api" },
    { name = "CORS_ALLOWED_ORIGINS", value = "" },
    { name = "UPLOAD_MAX_SIZE_MB", value = "500" },
    { name = "UPLOAD_STAGING_DIR", value = "/app/staging" },
    { name = "STORAGE_PROVIDER", value = "s3" },
    { name = "S3_BUCKET", value = aws_s3_bucket.this.id },
    { name = "S3_REGION", value = var.region },
    # No S3 keys: the images detect the task role through the container
    # credential endpoint. A static key would win over the role if one leaked in.
    { name = "DATABASE_SSL_MODE", value = "require" },
    # Settings insists on this even though DATABASE_URL_OVERRIDE carries the
    # real credential, so it is a placeholder rather than a secret.
    { name = "POSTGRES_PASSWORD", value = "unused-database-url-override-in-use" },
    { name = "PROCRASTINATE_SCHEMA", value = "catalog" },
  ]

  cache_env = var.cache_enabled ? [
    { name = "REDIS_URL", value = "redis://${aws_elasticache_replication_group.this[0].primary_endpoint_address}:6379/0" },
  ] : []

  # Pinned to the secret VERSION, not just the secret. ECS reads secrets only
  # at task start, so an unversioned reference would leave running tasks on a
  # rotated DSN or JWT key. Naming the version changes every task definition
  # whenever the secret changes, which rolls the services and re-runs migrate.
  backend_secrets = [
    for key in [
      "DATABASE_URL_OVERRIDE",
      "JWT_SECRET_KEY",
      "GEOLENS_ADMIN_USERNAME",
      "GEOLENS_ADMIN_PASSWORD",
      ] : {
      name      = key
      valueFrom = "${aws_secretsmanager_secret.app.arn}:${key}::${aws_secretsmanager_secret_version.app.version_id}"
    }
  ]

  titiler_env = [
    { name = "GDAL_CACHEMAX", value = "200" },
    { name = "GDAL_DISABLE_READDIR_ON_OPEN", value = "EMPTY_DIR" },
    { name = "CPL_VSIL_CURL_ALLOWED_EXTENSIONS", value = ".tif,.tiff,.cog,.vrt" },
    { name = "GDAL_VRT_ENABLE_RAWRASTERBAND", value = "NO" },
    { name = "GDAL_VRT_RAWRASTERBAND_ALLOWED_SOURCE", value = "SIBLING_OR_CHILD_OF_VRT_PATH" },
    { name = "VSI_CACHE", value = "TRUE" },
    { name = "CPL_VSIL_CURL_CACHE_SIZE", value = "16777216" },
    { name = "GDAL_HTTP_MERGE_CONSECUTIVE_RANGES", value = "YES" },
    { name = "MALLOC_ARENA_MAX", value = "2" },
    { name = "AWS_DEFAULT_REGION", value = var.region },
  ]
}

resource "aws_ecs_cluster" "this" {
  name = var.name
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}-app"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.name}-worker"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "migrate" {
  name              = "/ecs/${var.name}-migrate"
  retention_in_days = 14
}

# ponytail: frontend + api + titiler share one task so no service discovery is
# needed; they reach each other over 127.0.0.1. Split into separate services
# with ECS Service Connect when they need to scale independently.
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 3072
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "frontend"
      image     = local.frontend_image
      essential = true

      portMappings = [{ containerPort = 8080, protocol = "tcp" }]

      environment = [
        { name = "API_UPSTREAM", value = "http://127.0.0.1:8000" },
        { name = "API_BASE_URL", value = "/api" },
        { name = "TILE_BASE_URL", value = "/api" },
        { name = "PUBLIC_APP_URL", value = local.public_app_url },
        # Must match the api's UPLOAD_MAX_SIZE_MB or nginx rejects the upload
        # before the api ever sees it.
        { name = "CLIENT_MAX_BODY_SIZE", value = "500m" },
        # Without this the edge treats the load balancer as the client, so
        # every request shares one rate-limit bucket and logs one IP.
        { name = "TRUSTED_PROXY_CIDRS", value = var.vpc_cidr },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "frontend"
        }
      }
    },
    {
      name      = "api"
      image     = local.api_image
      essential = true

      # The frontend overwrites X-Forwarded-For before proxying, so trusting
      # every forwarded address here is safe and gives the api the real client.
      command = ["sh", "-c", "uv run --no-dev uvicorn app.api.main:app --host 0.0.0.0 --port 8000 --workers 2 --timeout-keep-alive 5 --timeout-graceful-shutdown 30 --limit-max-requests 10000 --proxy-headers --forwarded-allow-ips='*'"]

      # Migrations run once in the migrate task instead. The entrypoint has no
      # advisory lock, so several api tasks starting together would race.
      environment = concat(local.backend_env, local.cache_env, [
        { name = "GEOLENS_API_RUN_MIGRATIONS", value = "false" },
        { name = "TITILER_BASE_URL", value = "http://127.0.0.1:8081" },
        # Only the api runs multiple uvicorn workers, and only its entrypoint
        # creates this directory. Setting it for the worker or the migrate task
        # crashes them on the first Counter() with a missing-file error.
        { name = "PROMETHEUS_MULTIPROC_DIR", value = "/tmp/prometheus-multiproc" },
      ])

      secrets = local.backend_secrets

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "api"
        }
      }
    },
    {
      name      = "titiler"
      image     = local.titiler_image
      essential = true

      # awsvpc gives the whole task one network namespace, so titiler cannot
      # keep its default 8000 next to the api.
      command = ["uvicorn", "titiler.application.main:app", "--host", "0.0.0.0", "--port", "8081", "--workers", "1"]

      environment = local.titiler_env

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "titiler"
        }
      }
    },
  ])
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 4096
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = local.api_image
      essential = true

      # The api image with the worker entrypoint, which is what the production
      # compose file does. Avoids a second image to keep in step.
      entryPoint = ["/app/scripts/worker-entrypoint.sh"]
      command    = ["sh", "-c", "uv run --no-dev python -m app.worker"]

      # No TITILER_BASE_URL here: only api-side code calls titiler (the tiles
      # router and the STAC source resolver). The worker imports the
      # storage-key helpers from that module and renders quicklooks
      # in-process, as in the prod compose file, which also leaves the worker
      # without it (codex review on #40).
      environment = concat(local.backend_env, local.cache_env, [
        { name = "GEOLENS_API_RUN_MIGRATIONS", value = "false" },
        { name = "WORKER_CONCURRENCY", value = "1" },
        { name = "WORKER_QUEUES", value = "priority,ingest,raster,ingest-auth-v2" },
        { name = "WORKER_SHUTDOWN_TIMEOUT", value = "30" },
      ])

      secrets = local.backend_secrets

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.worker.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "worker"
        }
      }
    },
  ])
}

resource "aws_ecs_task_definition" "migrate" {
  family                   = "${var.name}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "migrate"
      image     = local.api_image
      essential = true

      # Keep the image entrypoint (it sets HOME and the uv cache dir) but turn
      # off the migration it would run itself, then bootstrap and migrate here.
      # The script arrives base64 encoded because quoting a Python heredoc
      # through JSON and sh is a losing game.
      command = ["sh", "-c", "echo \"$GEOLENS_BOOTSTRAP_B64\" | base64 -d > /tmp/bootstrap.py && uv run --no-dev python /tmp/bootstrap.py && uv run --no-dev alembic upgrade heads"]

      environment = concat(local.backend_env, local.cache_env, [
        { name = "GEOLENS_API_RUN_MIGRATIONS", value = "false" },
        { name = "GEOLENS_BOOTSTRAP_B64", value = base64encode(file("${path.module}/migrate.py")) },
      ])

      secrets = local.backend_secrets

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.migrate.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "migrate"
        }
      }
    },
  ])
}

# ECS has no "run this task and wait" resource, so the AWS CLI does it. Runs on
# the first apply and again whenever the task definition changes (every image
# bump and every secret change) or the database instance is replaced, so a
# recovered or rebuilt RDS is bootstrapped before the services reach it. Needs
# the AWS CLI and the same credentials Terraform uses.
resource "terraform_data" "migrate" {
  triggers_replace = [
    aws_ecs_task_definition.migrate.arn,
    aws_db_instance.this.resource_id,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    environment = {
      CLUSTER   = aws_ecs_cluster.this.name
      TASK_DEF  = aws_ecs_task_definition.migrate.arn
      REGION    = var.region
      SUBNETS   = join(",", aws_subnet.public[*].id)
      SG        = aws_security_group.app.id
      LOG_GROUP = aws_cloudwatch_log_group.migrate.name
    }

    command = <<-SH
      set -e
      task=$(aws ecs run-task --region "$REGION" --cluster "$CLUSTER" \
        --task-definition "$TASK_DEF" --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=ENABLED}" \
        --query 'tasks[0].taskArn' --output text)
      echo "migrate task $task"
      aws ecs wait tasks-stopped --region "$REGION" --cluster "$CLUSTER" --tasks "$task"
      code=$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$task" \
        --query 'tasks[0].containers[0].exitCode' --output text)
      if [ "$code" != "0" ]; then
        echo "migration failed with exit code $code" >&2
        echo "logs: aws logs tail $LOG_GROUP --since 15m --format short" >&2
        exit 1
      fi
    SH
  }

  depends_on = [
    aws_db_instance.this,
    aws_secretsmanager_secret_version.app,
    aws_iam_role_policy.execution_secrets,
    aws_iam_role_policy_attachment.execution,
  ]
}

resource "aws_ecs_service" "app" {
  name            = "${var.name}-app"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.app_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "frontend"
    container_port   = 8080
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http, terraform_data.migrate]
}

resource "aws_ecs_service" "worker" {
  name            = "${var.name}-worker"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = true
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [terraform_data.migrate]
}
