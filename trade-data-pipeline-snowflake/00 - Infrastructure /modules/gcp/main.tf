# infrastructure/modules/gcp/main.tf
terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.34.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 4.34.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.1.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.7.2"
    }
  }
}

# Enable required Google Cloud APIs
resource "google_project_service" "required_apis" {
  for_each = toset([
    "compute.googleapis.com",
    "dataflow.googleapis.com",
    "composer.googleapis.com",
    "pubsub.googleapis.com",
    "storage.googleapis.com",
    "bigquery.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudscheduler.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "cloudbuild.googleapis.com"
  ])
  
  service = each.key
  disable_on_destroy = false
}

# Create service accounts
resource "google_service_account" "dataflow_sa" {
  account_id   = "${var.dataflow_service_account}-${var.environment}"
  display_name = "DataFlow Service Account for Trade Pipeline"
  description  = "Service account for DataFlow jobs in ${var.environment}"
  
  depends_on = [google_project_service.required_apis]
}

resource "google_service_account" "composer_sa" {
  account_id   = "${var.composer_service_account}-${var.environment}"
  display_name = "Composer Service Account for Trade Pipeline"
  description  = "Service account for Cloud Composer in ${var.environment}"
  
  depends_on = [google_project_service.required_apis]
}

resource "google_service_account" "storage_sa" {
  account_id   = "storage-sa-${var.environment}"
  display_name = "Storage Service Account for Snowflake Integration"
  description  = "Service account for GCS storage integration with Snowflake"
  
  depends_on = [google_project_service.required_apis]
}

# Grant IAM roles to service accounts
resource "google_project_iam_member" "dataflow_roles" {
  for_each = toset([
    "roles/dataflow.admin",
    "roles/dataflow.worker",
    "roles/pubsub.subscriber",
    "roles/pubsub.publisher",
    "roles/storage.admin",
    "roles/bigquery.dataEditor",
    "roles/iam.serviceAccountUser"
  ])
  
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.dataflow_sa.email}"
  
  depends_on = [google_service_account.dataflow_sa]
}

resource "google_project_iam_member" "composer_roles" {
  for_each = toset([
    "roles/composer.worker",
    "roles/composer.environmentAndStorageObjectViewer",
    "roles/cloudsql.client",
    "roles/pubsub.editor",
    "roles/storage.objectAdmin",
    "roles/iam.serviceAccountUser"
  ])
  
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.composer_sa.email}"
  
  depends_on = [google_service_account.composer_sa]
}

resource "google_project_iam_member" "storage_roles" {
  for_each = toset([
    "roles/storage.objectAdmin",
    "roles/storage.objectCreator",
    "roles/storage.objectViewer"
  ])
  
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.storage_sa.email}"
  
  depends_on = [google_service_account.storage_sa]
}

# Create Pub/Sub topic
resource "google_pubsub_topic" "trades" {
  name = "${var.pubsub_topic_name}-${var.environment}"
  
  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }
  
  message_retention_duration = "604800s"  # 7 days
  
  schema_settings {
    schema   = "projects/${var.project_id}/schemas/trade-schema"
    encoding = "JSON"
  }
  
  depends_on = [google_project_service.required_apis]
}

# Create Pub/Sub subscription for Dataflow
resource "google_pubsub_subscription" "dataflow" {
  name  = "${var.pubsub_subscription_name}-${var.environment}"
  topic = google_pubsub_topic.trades.name
  
  ack_deadline_seconds = 600
  
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
  
  enable_message_ordering    = true
  enable_exactly_once_delivery = true
  
  expiration_policy {
    ttl = ""  # Never expire
  }
  
  dead_letter_policy {
    dead_letter_topic = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }
  
  labels = {
    environment = var.environment
    consumer    = "dataflow"
  }
}

# Dead letter topic for failed messages
resource "google_pubsub_topic" "dead_letter" {
  name = "dead-letter-${var.environment}"
  
  labels = {
    environment = var.environment
    purpose     = "dead-letter"
  }
}

# Create GCS buckets
resource "google_storage_bucket" "buckets" {
  for_each = var.bucket_names
  
  name          = "${each.value}-${var.project_id}-${var.environment}"
  location      = var.region
  force_destroy = var.environment == "dev"  # Be careful with production
  
  uniform_bucket_level_access = true
  
  versioning {
    enabled = each.key == "backup" || each.key == "state"
  }
  
  lifecycle_rule {
    condition {
      age = 30
      with_state = "ANY"
    }
    action {
      type = "Delete"
    }
  }
  
  labels = {
    environment = var.environment
    purpose     = each.key
  }
  
  encryption {
    default_kms_key_name = google_kms_crypto_key.bucket_encryption.id
  }
}

# KMS key for bucket encryption
resource "google_kms_key_ring" "bucket_encryption" {
  name     = "bucket-encryption-${var.environment}"
  location = var.region
}

resource "google_kms_crypto_key" "bucket_encryption" {
  name            = "bucket-key-${var.environment}"
  key_ring        = google_kms_key_ring.bucket_encryption.id
  rotation_period = "7776000s"  # 90 days
  
  version_template {
    algorithm = "GOOGLE_SYMMETRIC_ENCRYPTION"
  }
}

# Create Dataflow job
resource "google_dataflow_job" "trade_processing" {
  name              = "${var.dataflow_job_name}-${var.environment}"
  template_gcs_path = var.dataflow_template_path
  temp_gcs_location = "gs://${google_storage_bucket.buckets["temp"].name}/temp"
  region            = var.region
  max_workers       = var.dataflow_max_workers
  
  parameters = {
    inputSubscription = google_pubsub_subscription.dataflow.id
    outputTable      = "${var.project_id}:TRADE_DATA.VALID_TRADES"
    rejectedTable    = "${var.project_id}:TRADE_DATA.REJECTED_TRADES"
    errorTable       = "${var.project_id}:TRADE_DATA.ERROR_LOGS"
    environment      = var.environment
  }
  
  on_delete = "cancel"
  
  service_account_email = google_service_account.dataflow_sa.email
  
  network = module.vpc.network_name
  subnetwork = "regions/${var.region}/subnetworks/${module.vpc.subnet_name}"
  
  ip_configuration = "WORKER_IP_PRIVATE"
  
  labels = {
    environment = var.environment
    pipeline    = "trade-processing"
  }
  
  depends_on = [
    google_project_service.required_apis,
    google_storage_bucket.buckets["temp"],
    google_pubsub_subscription.dataflow
  ]
}

# Create Cloud Composer environment
resource "google_composer_environment" "orchestration" {
  name   = "${var.composer_name}-${var.environment}"
  region = var.region
  config {
    node_config {
      zone         = "${var.region}-a"
      machine_type = var.composer_machine_type
      disk_size_gb = var.composer_disk_size_gb
      
      service_account = google_service_account.composer_sa.email
      
      ip_allocation_policy {
        cluster_secondary_range_name  = "pods"
        services_secondary_range_name = "services"
      }
      
      tags = ["composer", "airflow", var.environment]
    }
    
    software_config {
      image_version = "composer-2-airflow-2"
      
      env_variables = {
        AIRFLOW__CORE__FERNET_KEY              = random_password.fernet_key.result
        AIRFLOW__CORE__SQL_ALCHEMY_CONN_SECRET = "projects/${var.project_id}/secrets/airflow-db-connection"
        AIRFLOW__WEBSERVER__SECRET_KEY         = random_password.webserver_secret.result
        ENVIRONMENT                            = var.environment
        PROJECT_ID                             = var.project_id
      }
      
      pypi_packages = {
        "apache-airflow-providers-google"    = ">=8.0.0"
        "apache-airflow-providers-snowflake" = ">=4.0.0"
        "snowflake-connector-python"         = ">=3.0.0"
        "snowflake-sqlalchemy"               = ">=1.4.0"
        "apache-beam[gcp]"                   = ">=2.40.0"
        "google-cloud-pubsub"                = ">=2.13.0"
        "google-cloud-storage"               = ">=2.0.0"
        "google-cloud-bigquery"              = ">=3.0.0"
        "pandas-gbq"                         = ">=0.17.0"
      }
      
      airflow_config_overrides = {
        "core-dags_are_paused_at_creation" = "False"
        "core-load_examples"               = "False"
        "scheduler-catchup_by_default"     = "False"
        "webserver-expose_config"          = "False"
      }
    }
    
    private_environment_config {
      enable_private_endpoint    = true
      cloud_sql_ipv4_cidr_block = "10.1.0.0/16"
      web_server_ipv4_cidr_block = "10.2.0.0/16"
    }
    
    workloads_config {
      scheduler {
        cpu        = 0.5
        memory_gb  = 1.875
        storage_gb = 1
        count      = 1
      }
      web_server {
        cpu        = 0.5
        memory_gb  = 1.875
        storage_gb = 1
      }
      worker {
        cpu        = 0.5
        memory_gb  = 1.875
        storage_gb = 1
        min_count  = 1
        max_count  = var.composer_node_count
      }
    }
  }
  
  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }
  
  depends_on = [
    google_project_service.required_apis,
    google_service_account.composer_sa,
    google_kms_crypto_key.composer_encryption,
    time_sleep.api_activation
  ]
}

# Wait for APIs to be fully activated
resource "time_sleep" "api_activation" {
  depends_on = [google_project_service.required_apis]
  
  create_duration = "120s"
}

# KMS key for Composer encryption
resource "google_kms_key_ring" "composer_encryption" {
  name     = "composer-encryption-${var.environment}"
  location = var.region
}

resource "google_kms_crypto_key" "composer_encryption" {
  name            = "composer-key-${var.environment}"
  key_ring        = google_kms_key_ring.composer_encryption.id
  rotation_period = "7776000s"  # 90 days
  
  version_template {
    algorithm = "GOOGLE_SYMMETRIC_ENCRYPTION"
  }
}

# Generate Fernet key for Airflow
resource "random_password" "fernet_key" {
  length  = 32
  special = true
}

# Generate webserver secret
resource "random_password" "webserver_secret" {
  length  = 32
  special = true
}

# Create monitoring alert policies
resource "google_monitoring_alert_policy" "dataflow_failure" {
  display_name = "Dataflow Job Failure - ${var.environment}"
  combiner     = "OR"
  
  conditions {
    display_name = "Dataflow Job Failed"
    
    condition_threshold {
      filter     = "resource.type=\"dataflow_job\" AND metric.type=\"dataflow.googleapis.com/job/current_state\" AND resource.labels.job_name=\"${google_dataflow_job.trade_processing.name}\""
      comparison = "COMPARISON_LT"
      threshold_value = 3  # Running state
      duration   = "300s"
      
      trigger {
        count = 1
      }
      
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_MEAN"
      }
    }
  }
  
  notification_channels = [
    google_monitoring_notification_channel.email.id,
    google_monitoring_notification_channel.slack.id
  ]
  
  documentation {
    content = "The trade processing Dataflow job has failed. Please check the Dataflow job logs and Pub/Sub subscription status."
  }
  
  labels = {
    environment = var.environment
    severity    = "critical"
  }
}

resource "google_monitoring_alert_policy" "pubsub_backlog" {
  display_name = "Pub/Sub Backlog - ${var.environment}"
  combiner     = "OR"
  
  conditions {
    display_name = "High Message Backlog"
    
    condition_threshold {
      filter     = "resource.type=\"pubsub_subscription\" AND metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\" AND resource.labels.subscription_id=\"${google_pubsub_subscription.dataflow.name}\""
      comparison = "COMPARISON_GT"
      threshold_value = 10000
      duration   = "600s"
      
      trigger {
        count = 1
      }
      
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
      }
    }
  }
  
  notification_channels = [
    google_monitoring_notification_channel.email.id
  ]
  
  documentation {
    content = "Pub/Sub subscription has high undelivered message backlog. Check Dataflow job health and processing rate."
  }
  
  labels = {
    environment = var.environment
    severity    = "warning"
  }
}

# Create notification channels
resource "google_monitoring_notification_channel" "email" {
  display_name = "Email Notifications - ${var.environment}"
  type         = "email"
  
  labels = {
    email_address = var.alert_notification_email
  }
}

resource "google_monitoring_notification_channel" "slack" {
  count = var.alert_notification_slack != "" ? 1 : 0
  
  display_name = "Slack Notifications - ${var.environment}"
  type         = "slack"
  
  labels = {
    channel_name = "#alerts"
  }
  
  sensitive_labels {
    auth_token = var.alert_notification_slack
  }
}

# Create Cloud Build trigger for CI/CD
resource "google_cloudbuild_trigger" "pipeline_deployment" {
  name        = "trade-pipeline-deployment-${var.environment}"
  description = "Deploy trade processing pipeline"
  
  trigger_template {
    branch_name = var.environment == "prod" ? "main" : var.environment
    repo_name   = "trade-data-pipeline"
  }
  
  filename = "cloudbuild.yaml"
  
  substitutions = {
    _ENVIRONMENT = var.environment
    _PROJECT_ID  = var.project_id
    _REGION      = var.region
  }
  
  tags = ["trade-pipeline", var.environment]
}

# Create budget alert
resource "google_billing_budget" "monthly" {
  billing_account = var.billing_account
  display_name    = "Monthly Budget - ${var.environment}"
  
  budget_filter {
    projects = ["projects/${var.project_id}"]
  }
  
  amount {
    specified_amount {
      currency_code = "USD"
      units         = var.budget_amount
    }
  }
  
  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.75
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }
  
  notification_rule_set {
    disable_default_iam_recipients = true
    
    monitoring_notification_channels = [
      google_monitoring_notification_channel.email.id
    ]
    
    enable_project_level_recipients = true
  }
}

# VPC Module
module "vpc" {
  source = "../vpc"
  
  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  
  network_name    = var.vpc_name
  subnet_name     = var.subnet_name
  subnet_cidr     = var.subnet_cidr
  subnet_region   = var.region
  
  allowed_ingress_ranges = var.allowed_ingress_ranges
  allowed_egress_ranges  = var.allowed_egress_ranges
  
  enable_private_service_access = true
}
