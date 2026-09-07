locals {
  api_image      = "ghcr.io/geolens-io/geolens-api:${var.geolens_version}"
  frontend_image = "ghcr.io/geolens-io/geolens-frontend:${var.geolens_version}"
  titiler_image  = "ghcr.io/developmentseed/titiler:${var.titiler_version}"

  # Shared by api, worker and the migrate task. Maps rather than lists so a
  # later merge can override a name instead of emitting it twice; ECS does not
  # define which duplicate wins.
  backend_env = merge({
    ENVIRONMENT          = "production"
    LOG_JSON             = "true"
    PUBLIC_APP_URL       = local.public_app_url
    PUBLIC_API_URL       = "${local.public_app_url}/api"
    CORS_ALLOWED_ORIGINS = ""
    UPLOAD_MAX_SIZE_MB   = tostring(var.upload_max_size_mb)
    UPLOAD_STAGING_DIR   = "/app/staging"
    STORAGE_PROVIDER     = "s3"
    S3_BUCKET            = aws_s3_bucket.this.id
    S3_REGION            = var.region
    # No S3 keys: the images detect the task role through the container
    # credential endpoint. A static key would win over the role if one leaked in.
    DATABASE_SSL_MODE = "require"
    # Settings insists on this even though DATABASE_URL_OVERRIDE carries the
    # real credential, so it is a placeholder rather than a secret.
    POSTGRES_PASSWORD    = "unused-database-url-override-in-use"
    PROCRASTINATE_SCHEMA = "catalog"
    # Not read by the app. Changing it changes every task definition, which is
    # the redeploy that makes a rotated extra secret take effect.
    EXTRA_SECRETS_REVISION = var.extra_secrets_revision
    }, var.cache_enabled ? {
    REDIS_URL = "redis://${aws_elasticache_replication_group.this[0].primary_endpoint_address}:6379/0"
  } : {})

  # Pinned to the secret VERSION, not just the secret. ECS reads secrets only
  # at task start, so an unversioned reference would leave running tasks on a
  # rotated DSN or JWT key. Naming the version changes every task definition
  # whenever the secret changes, which rolls the services and re-runs migrate.
  app_secrets = [
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

  backend_secrets = concat(local.app_secrets, [
    for name, value_from in var.extra_secrets : { name = name, valueFrom = value_from }
  ])

  # One awslogs block per container, all in the same shape.
  log = { for name, group in {
    frontend = aws_cloudwatch_log_group.app.name
    api      = aws_cloudwatch_log_group.app.name
    titiler  = aws_cloudwatch_log_group.app.name
    worker   = aws_cloudwatch_log_group.worker.name
    migrate  = aws_cloudwatch_log_group.migrate.name
    } : name => {
    logDriver = "awslogs"
    options = {
      awslogs-group         = group
      awslogs-region        = var.region
      awslogs-stream-prefix = name
    }
  } }

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
  cpu                      = var.app_task.cpu
  memory                   = var.app_task.memory
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
        { name = "CLIENT_MAX_BODY_SIZE", value = "${var.upload_max_size_mb}m" },
        # Without this the edge treats the load balancer as the client, so
        # every request shares one rate-limit bucket and logs one IP.
        { name = "TRUSTED_PROXY_CIDRS", value = var.vpc_cidr },
      ]

      logConfiguration = local.log.frontend
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
      environment = [for k, v in merge(local.backend_env, {
        GEOLENS_API_RUN_MIGRATIONS = "false"
        TITILER_BASE_URL           = "http://127.0.0.1:8081"
        # Only the api runs multiple uvicorn workers, and only its entrypoint
        # creates this directory. Setting it for the worker or the migrate task
        # crashes them on the first Counter() with a missing-file error.
        PROMETHEUS_MULTIPROC_DIR = "/tmp/prometheus-multiproc"
      }, var.extra_env) : { name = k, value = v }]

      secrets = local.backend_secrets

      # Process-only, like the chart's liveness probe: /health also probes the
      # database and object store, and restarting the api for a dependency
      # outage would hide the cause. The ALB's /api/health is the readiness view.
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8000/health/live')\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      logConfiguration = local.log.api
    },
    {
      name      = "titiler"
      image     = local.titiler_image
      essential = true

      # awsvpc gives the whole task one network namespace, so titiler cannot
      # keep its default 8000 next to the api.
      command = ["uvicorn", "titiler.application.main:app", "--host", "0.0.0.0", "--port", "8081", "--workers", "1"]

      environment = local.titiler_env

      # The ALB probe covers the api's dependencies, not a hung tile renderer.
      # Same /healthz the chart's liveness probe uses (codex review on #40).
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8081/healthz')\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }

      logConfiguration = local.log.titiler
    },
  ])
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_task.cpu
  memory                   = var.worker_task.memory
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
      environment = [for k, v in merge(local.backend_env, {
        GEOLENS_API_RUN_MIGRATIONS = "false"
        WORKER_CONCURRENCY         = tostring(var.worker_concurrency)
        WORKER_QUEUES              = "priority,ingest,raster,ingest-auth-v2"
        WORKER_SHUTDOWN_TIMEOUT    = "30"
      }, var.extra_env) : { name = k, value = v }]

      secrets = local.backend_secrets

      # Nothing else watches the worker: no load balancer target, and a hung
      # job runner keeps the process alive. Same probe the image HEALTHCHECK
      # and the chart's liveness probe use; failing it stops the task and the
      # service replaces it (codex review on #40). The health server only
      # starts after schema sync and storage bootstrap, hence the start period.
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8001/health/live')\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 120
      }

      logConfiguration = local.log.worker
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

      environment = [for k, v in merge(local.backend_env, {
        GEOLENS_API_RUN_MIGRATIONS = "false"
        GEOLENS_BOOTSTRAP_B64      = base64encode(file("${path.module}/migrate.py"))
      }, var.extra_env) : { name = k, value = v }]

      secrets = local.backend_secrets

      logConfiguration = local.log.migrate
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
      # Not `aws ecs wait tasks-stopped`: that waiter gives up after ten
      # minutes with exit 255, and a retry would start a second migration next
      # to one still running (codex review on #40). Poll for up to an hour.
      deadline=$(( $(date +%s) + 3600 ))
      while :; do
        status=$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$task" \
          --query 'tasks[0].lastStatus' --output text)
        [ "$status" = "STOPPED" ] && break
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "migration still $status after 1h; inspect it before retrying: aws ecs describe-tasks --cluster $CLUSTER --tasks $task" >&2
          exit 1
        fi
        sleep 10
      done
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

  # Both listeners: with a certificate only the HTTPS one attaches the target
  # group, and ECS rejects a service whose target group has no load balancer
  # yet (codex review on #40).
  depends_on = [aws_lb_listener.http, aws_lb_listener.https, terraform_data.migrate]
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
