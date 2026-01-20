# infrastructure/variables.tf
# Variable validation script against the values present in terraform.tfvars
# The validation need to be successful in order to TF scripts to proceed further
#
variable "project_id" {
  description = "GCP Project ID"
  type        = string
  validation {
    condition     = length(var.project_id) > 0
    error_message = "Project ID must not be empty."
  }
}

variable "region" {
  description = "GCP region for resources"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
  
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "billing_account" {
  description = "Billing account ID"
  type        = string
  sensitive   = true
}

variable "org_id" {
  description = "Organization ID"
  type        = string
}

# GCP Networking Variables
variable "vpc_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "trade-pipeline-vpc"
}

variable "subnet_name" {
  description = "Name of the subnet"
  type        = string
  default     = "trade-pipeline-subnet"
}

variable "subnet_cidr" {
  description = "CIDR range for the subnet"
  type        = string
  default     = "10.0.0.0/24"
}

variable "allowed_ingress_ranges" {
  description = "List of CIDR ranges allowed for ingress"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # Restrict in production
}

variable "allowed_egress_ranges" {
  description = "List of CIDR ranges allowed for egress"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Pub/Sub Variables
variable "pubsub_topic_name" {
  description = "Name of the Pub/Sub topic"
  type        = string
  default     = "trades-topic"
}

variable "pubsub_subscription_name" {
  description = "Name of the Pub/Sub subscription"
  type        = string
  default     = "trades-dataflow-sub"
}

# Dataflow Variables
variable "dataflow_job_name" {
  description = "Name of the Dataflow job"
  type        = string
  default     = "trade-processing"
}

variable "dataflow_template_path" {
  description = "GCS path to Dataflow template"
  type        = string
  default     = "gs://dataflow-templates/latest/Cloud_PubSub_to_Snowflake"
}

variable "dataflow_max_workers" {
  description = "Maximum number of Dataflow workers"
  type        = number
  default     = 10
}

variable "dataflow_service_account" {
  description = "Service account for Dataflow"
  type        = string
  default     = "dataflow-sa"
}

# Composer Variables
variable "composer_name" {
  description = "Name of the Cloud Composer environment"
  type        = string
  default     = "trade-orchestration"
}

variable "composer_node_count" {
  description = "Number of nodes in Composer cluster"
  type        = number
  default     = 3
  validation {
    condition     = var.composer_node_count >= 3
    error_message = "Composer node count must be at least 3 for high availability."
  }
}

variable "composer_machine_type" {
  description = "Machine type for Composer nodes"
  type        = string
  default     = "n1-standard-2"
}

variable "composer_disk_size_gb" {
  description = "Disk size for Composer nodes (GB)"
  type        = number
  default     = 100
}

variable "composer_service_account" {
  description = "Service account for Composer"
  type        = string
  default     = "composer-sa"
}

# Storage Variables
variable "bucket_names" {
  description = "Map of bucket names and their purposes"
  type        = map(string)
  default = {
    "data"        = "trade-data"
    "temp"        = "trade-temp"
    "staging"     = "trade-staging"
    "backup"      = "trade-backup"
    "templates"   = "trade-templates"
    "state"       = "tf-state"
  }
}

# Snowflake Variables
variable "snowflake_account" {
  description = "Snowflake account identifier"
  type        = string
  sensitive   = true
}

variable "snowflake_username" {
  description = "Snowflake admin username"
  type        = string
  default     = "terraform"
  sensitive   = true
}

variable "snowflake_password" {
  description = "Snowflake admin password"
  type        = string
  sensitive   = true
}

variable "snowflake_database_name" {
  description = "Snowflake database name"
  type        = string
  default     = "TRADE_DB"
}

variable "snowflake_schemas" {
  description = "List of schemas to create"
  type        = list(string)
  default = [
    "RAW",
    "PROCESSED",
    "ANALYTICS",
    "AUDIT",
    "TEST"
  ]
}

variable "snowflake_data_retention_days" {
  description = "Data retention period in days"
  type        = number
  default     = 90
}

variable "snowflake_warehouses" {
  description = "Map of warehouse configurations"
  type = map(object({
    size           = string
    min_cluster_count = number
    max_cluster_count = number
    scaling_policy = string
    auto_suspend   = number
    initially_suspended = bool
  }))
  default = {
    "load" = {
      size           = "X-SMALL"
      min_cluster_count = 1
      max_cluster_count = 3
      scaling_policy = "STANDARD"
      auto_suspend   = 300
      initially_suspended = true
    }
    "transform" = {
      size           = "SMALL"
      min_cluster_count = 1
      max_cluster_count = 2
      scaling_policy = "ECONOMY"
      auto_suspend   = 300
      initially_suspended = true
    }
    "analytics" = {
      size           = "MEDIUM"
      min_cluster_count = 1
      max_cluster_count = 4
      scaling_policy = "STANDARD"
      auto_suspend   = 300
      initially_suspended = true
    }
  }
}

variable "snowflake_users" {
  description = "Map of users to create"
  type = map(object({
    login_name      = string
    display_name    = string
    email           = string
    default_role    = string
    default_warehouse = string
    rsa_public_key  = string
    must_change_password = bool
  }))
  default = {
    "trade_loader" = {
      login_name      = "TRADE_LOADER"
      display_name    = "Trade Data Loader"
      email           = "trade-loader@company.com"
      default_role    = "TRADE_LOADER"
      default_warehouse = "TRADE_LOAD_WH"
      rsa_public_key  = ""
      must_change_password = false
    }
    "trade_analyst" = {
      login_name      = "TRADE_ANALYST"
      display_name    = "Trade Analyst"
      email           = "trade-analyst@company.com"
      default_role    = "TRADE_ANALYST"
      default_warehouse = "TRADE_ANALYTICS_WH"
      rsa_public_key  = ""
      must_change_password = true
    }
    "trade_admin" = {
      login_name      = "TRADE_ADMIN"
      display_name    = "Trade Admin"
      email           = "trade-admin@company.com"
      default_role    = "TRADE_ADMIN"
      default_warehouse = "TRADE_TRANSFORM_WH"
      rsa_public_key  = ""
      must_change_password = false
    }
  }
}

variable "snowflake_roles" {
  description = "Map of roles to create with privileges"
  type = map(object({
    granted_to_users = list(string)
    warehouse_grants = map(list(string))
    database_grants  = map(list(string))
    schema_grants    = map(map(list(string)))
  }))
  default = {
    "TRADE_LOADER" = {
      granted_to_users = ["trade_loader"]
      warehouse_grants = {
        "TRADE_LOAD_WH" = ["USAGE", "OPERATE"]
      }
      database_grants = {
        "TRADE_DB" = ["USAGE"]
      }
      schema_grants = {
        "TRADE_DB" = {
          "RAW"       = ["USAGE", "CREATE TABLE", "INSERT", "SELECT"]
          "PROCESSED" = ["USAGE", "INSERT", "SELECT", "UPDATE"]
        }
      }
    }
    "TRADE_ANALYST" = {
      granted_to_users = ["trade_analyst"]
      warehouse_grants = {
        "TRADE_ANALYTICS_WH" = ["USAGE"]
      }
      database_grants = {
        "TRADE_DB" = ["USAGE"]
      }
      schema_grants = {
        "TRADE_DB" = {
          "ANALYTICS" = ["SELECT"]
          "PROCESSED" = ["SELECT"]
        }
      }
    }
    "TRADE_ADMIN" = {
      granted_to_users = ["trade_admin"]
      warehouse_grants = {
        "TRADE_TRANSFORM_WH" = ["USAGE", "OPERATE", "MONITOR"]
      }
      database_grants = {
        "TRADE_DB" = ["ALL PRIVILEGES"]
      }
      schema_grants = {
        "TRADE_DB" = {
          "*" = ["ALL PRIVILEGES"]
        }
      }
    }
  }
}

variable "snowflake_storage_allowed_locations" {
  description = "GCS locations allowed for Snowflake storage integration"
  type        = list(string)
  default = [
    "gcs://trade-data-*/",
    "gcs://trade-staging-*/",
    "gcs://trade-backup-*/"
  ]
}

variable "snowflake_allowed_ip_ranges" {
  description = "IP ranges allowed to connect to Snowflake"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # Restrict in production
}

# Monitoring Variables
variable "alert_notification_email" {
  description = "Email for alert notifications"
  type        = string
  default     = "data-engineering@company.com"
}

variable "alert_notification_slack" {
  description = "Slack webhook URL for notifications"
  type        = string
  sensitive   = true
  default     = ""
}

# Cost Management
variable "budget_amount" {
  description = "Monthly budget amount in USD"
  type        = number
  default     = 1000
}

variable "budget_alert_thresholds" {
  description = "Budget alert thresholds as percentages"
  type        = list(number)
  default     = [50, 75, 90, 100]
}
