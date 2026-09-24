locals {
  api_image      = "ghcr.io/geolens-io/geolens-api:${var.geolens_version}"
  frontend_image = "ghcr.io/geolens-io/geolens-frontend:${var.geolens_version}"
  titiler_image  = "ghcr.io/developmentseed/titiler:${var.titiler_version}"

  # Env name to Container Apps secret name. The names are not secret; the
  # values in local.app_secrets are.
  secret_names       = { for k in nonsensitive(keys(local.app_secrets)) : k => lower(replace(k, "_", "-")) }
  extra_secret_names = nonsensitive(keys(var.extra_secrets))

  # Not read by the app. Container Apps leaves running replicas on the old
  # value of a changed secret, so a digest of every value goes into each
  # template: changing one changes the template, which rolls a new revision
  # and re-runs the migrate job.
  secrets_revision = nonsensitive(substr(sha256(jsonencode(local.app_secrets)), 0, 16))

  backend_env = {
    ENVIRONMENT               = "production"
    LOG_JSON                  = "true"
    PUBLIC_APP_URL            = local.public_app_url
    PUBLIC_API_URL            = "${local.public_app_url}/api"
    CORS_ALLOWED_ORIGINS      = ""
    UPLOAD_MAX_SIZE_MB        = tostring(var.upload_max_size_mb)
    UPLOAD_STAGING_DIR        = "/app/staging"
    STORAGE_PROVIDER          = "azure"
    AZURE_STORAGE_CONTAINER   = azurerm_storage_container.uploads.name
    AZURE_STORAGE_ACCOUNT_URL = trimsuffix(azurerm_storage_account.this.primary_blob_endpoint, "/")
    DATABASE_SSL_MODE         = "require"
    # Settings insists on this even though DATABASE_URL_OVERRIDE carries the
    # real credential, so it is a placeholder rather than a secret.
    POSTGRES_PASSWORD    = "unused-database-url-override-in-use"
    PROCRASTINATE_SCHEMA = "catalog"
    SECRETS_REVISION     = local.secrets_revision
  }

  # Plain env per backend container: the shared defaults, the container's own,
  # then extra_env over both. An extra_secrets entry drops the plain variable
  # of the same name, since Container Apps would otherwise pass both.
  backend_env_for = { for role, own in {
    api = {
      # Migrations run once in the migrate job instead. The entrypoint has no
      # advisory lock, so several api replicas starting together would race.
      GEOLENS_API_RUN_MIGRATIONS = "false"
      TITILER_BASE_URL           = "http://127.0.0.1:8081"
      # The image's own command reads these. The frontend overwrites
      # X-Forwarded-For before proxying, so trusting it gives the api the
      # real client.
      UVICORN_WORKERS      = "2"
      UVICORN_MAX_REQUESTS = "10000"
      FORWARDED_ALLOW_IPS  = "*"
      # Only the api runs several uvicorn workers, and only its entrypoint
      # creates this directory; the worker and migrate job crash on it.
      PROMETHEUS_MULTIPROC_DIR = "/tmp/prometheus-multiproc"
    }
    worker = {
      GEOLENS_API_RUN_MIGRATIONS = "false"
      WORKER_CONCURRENCY         = tostring(var.worker_concurrency)
      WORKER_SHUTDOWN_TIMEOUT    = "30"
    }
    migrate = {
      GEOLENS_API_RUN_MIGRATIONS = "false"
      GEOLENS_BOOTSTRAP_B64      = base64encode(file("${path.module}/migrate.py"))
    }
    } : role => {
    for k, v in merge(local.backend_env, own, var.extra_env) : k => v if !contains(local.extra_secret_names, k)
  } }

  frontend_env = {
    API_UPSTREAM   = "http://127.0.0.1:8000"
    API_BASE_URL   = "/api"
    TILE_BASE_URL  = "/api"
    PUBLIC_APP_URL = local.public_app_url
    # Must match the api's UPLOAD_MAX_SIZE_MB or nginx rejects the upload
    # before the api ever sees it.
    CLIENT_MAX_BODY_SIZE = "${var.upload_max_size_mb}m"
    # The ingress proxies connect from the ranges a workload profiles
    # environment reserves for itself, not from the virtual network. Without
    # them every request shares one rate-limit bucket and logs one IP.
    TRUSTED_PROXY_CIDRS = "100.100.0.0/17,100.100.128.0/19,100.100.160.0/19,100.100.192.0/19"
  }

  titiler_env = {
    GDAL_CACHEMAX                         = "200"
    GDAL_DISABLE_READDIR_ON_OPEN          = "EMPTY_DIR"
    CPL_VSIL_CURL_ALLOWED_EXTENSIONS      = ".tif,.tiff,.cog,.vrt"
    GDAL_VRT_ENABLE_RAWRASTERBAND         = "NO"
    GDAL_VRT_RAWRASTERBAND_ALLOWED_SOURCE = "SIBLING_OR_CHILD_OF_VRT_PATH"
    VSI_CACHE                             = "TRUE"
    CPL_VSIL_CURL_CACHE_SIZE              = "16777216"
    GDAL_HTTP_MERGE_CONSECUTIVE_RANGES    = "YES"
    MALLOC_ARENA_MAX                      = "2"
    # GDAL's /vsiaz/ reads its own variables, not the app's: the account name
    # alone here, and the same key as the app's under AZURE_STORAGE_ACCESS_KEY.
    AZURE_STORAGE_ACCOUNT = azurerm_storage_account.this.name
    SECRETS_REVISION      = local.secrets_revision
  }
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.name}-logs"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# Consumption only, so the environment itself costs nothing; the dedicated-plan
# management fee applies to dedicated profiles and private endpoints. Azure
# creates the infrastructure resource group and deletes it with the environment.
resource "azurerm_container_app_environment" "this" {
  name                               = "${var.name}-env"
  resource_group_name                = azurerm_resource_group.this.name
  location                           = azurerm_resource_group.this.location
  logs_destination                   = "log-analytics"
  log_analytics_workspace_id         = azurerm_log_analytics_workspace.this.id
  infrastructure_subnet_id           = azurerm_subnet.apps.id
  infrastructure_resource_group_name = "${var.name}-rg-infra"
  tags                               = local.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

# The staging share (data.tf), registered with the environment so the api and
# the worker can mount it at /app/staging.
resource "azurerm_container_app_environment_storage" "staging" {
  name                         = "staging"
  container_app_environment_id = azurerm_container_app_environment.this.id
  account_name                 = azurerm_storage_account.this.name
  share_name                   = azurerm_storage_share.staging.name
  access_key                   = azurerm_storage_account.this.primary_access_key
  access_mode                  = "ReadWrite"
}

# ponytail: frontend + api + titiler share one app so no service discovery is
# needed; they reach each other over 127.0.0.1. Split them into separate apps
# when they need to scale independently.
resource "azurerm_container_app" "app" {
  name                         = "${var.name}-app"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  dynamic "secret" {
    for_each = local.secret_names
    content {
      name  = secret.value
      value = local.app_secrets[secret.key]
    }
  }

  # The frontend is the only way in: it proxies /api, maps /raster-tiles,
  # blocks /api/metrics and rate-limits anonymous raster traffic. Container
  # Apps terminates TLS and redirects plain HTTP.
  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # ponytail: no scale to zero, since the api takes the better part of a
    # minute to start. Drop min_replicas to 0 when idle cost matters more.
    min_replicas = var.app_replicas
    max_replicas = var.app_replicas

    # SMB shows every file as owned by the mount's uid, and only the owner may
    # set file times, which the raster pipeline's copies do; 1001 is the
    # images' appuser.
    volume {
      name          = "staging"
      storage_type  = "AzureFile"
      storage_name  = azurerm_container_app_environment_storage.staging.name
      mount_options = "uid=1001,gid=1001,dir_mode=0750,file_mode=0640"
    }

    container {
      name   = "frontend"
      image  = local.frontend_image
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "env" {
        for_each = local.frontend_env
        content {
          name  = env.key
          value = env.value
        }
      }

      readiness_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/"
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/"
      }
    }

    container {
      name   = "api"
      image  = local.api_image
      cpu    = var.api_cpu
      memory = "${var.api_cpu * 2}Gi"

      volume_mounts {
        name = "staging"
        path = "/app/staging"
      }

      dynamic "env" {
        for_each = local.backend_env_for.api
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_names
        content {
          name        = env.key
          secret_name = env.value
        }
      }

      # Process-only, like the chart's probes and the AWS recipe's: /health
      # also probes the database, object store and cache, and restarting the
      # api for a dependency outage would hide the cause. The api waits on
      # the database at boot, hence the five minutes to start.
      startup_probe {
        transport               = "HTTP"
        port                    = 8000
        path                    = "/health/live"
        interval_seconds        = 10
        failure_count_threshold = 30
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = 8000
        path                    = "/health/live"
        interval_seconds        = 30
        failure_count_threshold = 3
      }

      readiness_probe {
        transport = "HTTP"
        port      = 8000
        path      = "/health/live"
      }
    }

    container {
      name   = "titiler"
      image  = local.titiler_image
      cpu    = 0.5
      memory = "1Gi"

      # One network namespace per replica, so titiler cannot keep its default
      # 8000 next to the api. The image has no entrypoint, so this command is
      # the whole invocation.
      command = ["uvicorn", "titiler.application.main:app", "--host", "0.0.0.0", "--port", "8081", "--workers", "1"]

      dynamic "env" {
        for_each = local.titiler_env
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name        = "AZURE_STORAGE_ACCESS_KEY"
        secret_name = local.secret_names["AZURE_STORAGE_ACCOUNT_KEY"]
      }

      startup_probe {
        transport               = "HTTP"
        port                    = 8081
        path                    = "/healthz"
        interval_seconds        = 5
        failure_count_threshold = 12
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = 8081
        path                    = "/healthz"
        interval_seconds        = 30
        failure_count_threshold = 3
      }
    }
  }

  depends_on = [terraform_data.migrate]
}

resource "azurerm_container_app" "worker" {
  name                         = "${var.name}-worker"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  dynamic "secret" {
    for_each = local.secret_names
    content {
      name  = secret.value
      value = local.app_secrets[secret.key]
    }
  }

  # No ingress. An app without ingress has nothing to scale it up from zero,
  # so the worker is pinned at one replica or queued imports never run.
  template {
    min_replicas = 1
    max_replicas = 1

    # Compose's 35s: the kill lands after the worker's own 30s shutdown
    # window, so it releases its jobs first.
    termination_grace_period_seconds = 35

    volume {
      name          = "staging"
      storage_type  = "AzureFile"
      storage_name  = azurerm_container_app_environment_storage.staging.name
      mount_options = "uid=1001,gid=1001,dir_mode=0750,file_mode=0640"
    }

    container {
      name   = "worker"
      image  = local.api_image
      cpu    = var.worker_cpu
      memory = "${var.worker_cpu * 2}Gi"

      # The api image with the worker entrypoint, as the production compose
      # file runs it. Here command replaces the image entrypoint and args its
      # command.
      command = ["/app/scripts/worker-entrypoint.sh"]
      args    = ["sh", "-c", "uv run --no-dev python -m app.worker"]

      # No TITILER_BASE_URL and no WORKER_QUEUES, as on AWS: only api-side code
      # calls titiler, and the image default names every queue its release
      # enqueues to.
      volume_mounts {
        name = "staging"
        path = "/app/staging"
      }

      dynamic "env" {
        for_each = local.backend_env_for.worker
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_names
        content {
          name        = env.key
          secret_name = env.value
        }
      }

      # Nothing else watches the worker, and a hung job runner keeps the
      # process alive. The health server starts only after schema sync and
      # storage bootstrap, hence the long start.
      startup_probe {
        transport               = "HTTP"
        port                    = 8001
        path                    = "/health/live"
        interval_seconds        = 10
        failure_count_threshold = 30
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = 8001
        path                    = "/health/live"
        interval_seconds        = 30
        failure_count_threshold = 3
      }
    }
  }

  depends_on = [terraform_data.migrate]
}

resource "azurerm_container_app_job" "migrate" {
  name                         = "${var.name}-migrate"
  resource_group_name          = azurerm_resource_group.this.name
  location                     = azurerm_resource_group.this.location
  container_app_environment_id = azurerm_container_app_environment.this.id
  workload_profile_name        = "Consumption"
  replica_timeout_in_seconds   = 3600
  # A failed migration is looked at, not retried next to itself.
  replica_retry_limit = 0
  tags                = local.tags

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  dynamic "secret" {
    for_each = local.secret_names
    content {
      name  = secret.value
      value = local.app_secrets[secret.key]
    }
  }

  template {
    container {
      name   = "migrate"
      image  = local.api_image
      cpu    = 0.5
      memory = "1Gi"

      # Only the image command is replaced: its entrypoint sets HOME and the
      # uv cache directory, and GEOLENS_API_RUN_MIGRATIONS=false stops it
      # migrating on its own. The bootstrap arrives base64 encoded because
      # quoting Python through HCL and sh is a losing game. The hand-back runs
      # whether or not alembic succeeds, and failing it fails the job.
      args = ["sh", "-c", "echo \"$GEOLENS_BOOTSTRAP_B64\" | base64 -d > /tmp/bootstrap.py && uv run --no-dev python /tmp/bootstrap.py && { uv run --no-dev alembic upgrade heads; rc=$?; uv run --no-dev python /tmp/bootstrap.py --hand-back || rc=1; exit $rc; }"]

      dynamic "env" {
        for_each = local.backend_env_for.migrate
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_names
        content {
          name        = env.key
          secret_name = env.value
        }
      }
    }
  }
}

# Container Apps has no "run this job and wait" resource, so the Azure CLI
# does it. Runs on the first apply and again whenever the image, the backend
# env or any secret changes, or the database server is replaced, so a rebuilt
# server is bootstrapped before the apps reach it. Needs az, logged in to the
# subscription Terraform uses.
resource "terraform_data" "migrate" {
  triggers_replace = [
    azurerm_container_app_job.migrate.id,
    sha256(jsonencode([local.api_image, local.backend_env_for.migrate])),
    azurerm_postgresql_flexible_server.this.id,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    environment = {
      SUBSCRIPTION = var.subscription_id
      RG           = azurerm_resource_group.this.name
      JOB          = azurerm_container_app_job.migrate.name
    }

    command = <<-SH
      set -e
      run=$(az containerapp job start --subscription "$SUBSCRIPTION" --resource-group "$RG" \
        --name "$JOB" --query name --output tsv)
      echo "migrate execution $run"
      # Poll for up to an hour, the job's own replica timeout. A failure is
      # reported rather than retried, so two migrations never overlap.
      deadline=$(( $(date +%s) + 3660 ))
      while :; do
        status=$(az containerapp job execution show --subscription "$SUBSCRIPTION" --resource-group "$RG" \
          --name "$JOB" --job-execution-name "$run" --query properties.status --output tsv)
        case "$status" in
          Succeeded) exit 0 ;;
          Failed|Stopped|Degraded)
            echo "migration $status" >&2
            echo "logs: az containerapp job logs show --resource-group $RG --name $JOB --execution $run --container migrate" >&2
            exit 1 ;;
        esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "migration still $status after 1h; inspect it before retrying: az containerapp job execution show --resource-group $RG --name $JOB --job-execution-name $run" >&2
          exit 1
        fi
        sleep 10
      done
    SH
  }

  depends_on = [
    azurerm_postgresql_flexible_server_configuration.extensions,
    azurerm_postgresql_flexible_server_database.geolens,
    azurerm_storage_container.uploads,
  ]
}
