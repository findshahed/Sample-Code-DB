# infrastructure/modules/snowflake/main.tf
# Following activities are performed in this script
# Generate random passwords for users
# Create database
# Create schemas
# Create Virtual warehouses
# Create roles
# Grant database privileges to roles
# Grant schema privileges to roles
# Grant warehouse privileges to roles
# Create users
# Grant roles to users
# Create storage integration for GCS
# Create network policy
# Apply network policy to account
# Create external tables (optional)
# Create file format for JSON
# Create stage for Snowpipe
# Create Snowpipe
# Create tasks for data transformation
# Create streams for CDC
# Create masking policy for sensitive data
# Apply masking policy
# Create resource monitor for cost control
# Assign resource monitor to warehouses
#

terraform {
  required_version = ">= 1.0"
  required_providers {
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = ">= 0.40.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.1.0"
    }
  }
}

# Generate random passwords for users
resource "random_password" "user_passwords" {
  for_each = var.users
  
  length  = 16
  special = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
  
  keepers = {
    user = each.key
  }
}

# Create database
resource "snowflake_database" "trade_db" {
  name                        = "${var.database_name}_${upper(var.environment)}"
  comment                     = "Trade processing database for ${var.environment} environment"
  data_retention_time_in_days = var.data_retention_days
  
  from_share {
    provider = ""
    share    = ""
  }
}

# Create schemas
resource "snowflake_schema" "schemas" {
  for_each = toset(var.schemas)
  
  database = snowflake_database.trade_db.name
  name     = each.key
  
  is_managed         = false
  data_retention_days = var.data_retention_days
  
  comment = "${each.key} schema for trade data"
}

# Create warehouses
resource "snowflake_warehouse" "warehouses" {
  for_each = var.warehouses
  
  name           = "TRADE_${upper(each.key)}_WH_${upper(var.environment)}"
  warehouse_size = each.value.size
  
  auto_suspend          = each.value.auto_suspend
  auto_resume           = true
  initially_suspended   = each.value.initially_suspended
  max_cluster_count     = each.value.max_cluster_count
  min_cluster_count     = each.value.min_cluster_count
  scaling_policy        = each.value.scaling_policy
  statement_timeout_in_seconds = 86400
  
  comment = "${each.key} warehouse for trade pipeline in ${var.environment}"
}

# Create roles
resource "snowflake_role" "roles" {
  for_each = var.roles
  
  name    = "${each.key}_${upper(var.environment)}"
  comment = "${each.key} role for trade pipeline"
}

# Grant database privileges to roles
resource "snowflake_database_grant" "database_grants" {
  for_each = { for role, config in var.roles : role => config.database_grants }
  
  database_name = snowflake_database.trade_db.name
  
  privilege = "USAGE"
  roles     = [snowflake_role.roles[each.key].name]
  
  with_grant_option = false
}

# Grant schema privileges to roles
resource "snowflake_schema_grant" "schema_grants" {
  for_each = { for role, config in var.roles : role => config }
  
  database_name = snowflake_database.trade_db.name
  
  for schema, privileges in each.value.schema_grants[snowflake_database.trade_db.name] {
    schema_name   = schema
    privilege     = "USAGE"
    roles         = [snowflake_role.roles[each.key].name]
    with_grant_option = false
  }
}

# Grant warehouse privileges to roles
resource "snowflake_warehouse_grant" "warehouse_grants" {
  for_each = { for role, config in var.roles : role => config }
  
  for warehouse, privileges in each.value.warehouse_grants {
    warehouse_name = snowflake_warehouse.warehouses[warehouse].name
    privilege      = "USAGE"
    roles          = [snowflake_role.roles[each.key].name]
    with_grant_option = false
  }
}

# Create users
resource "snowflake_user" "users" {
  for_each = var.users
  
  name                 = "${each.value.login_name}_${upper(var.environment)}"
  display_name         = each.value.display_name
  email                = each.value.email
  default_role         = snowflake_role.roles[each.value.default_role].name
  default_warehouse    = snowflake_warehouse.warehouses[each.value.default_warehouse].name
  rsa_public_key       = each.value.rsa_public_key
  must_change_password = each.value.must_change_password
  
  password = random_password.user_passwords[each.key].result
  
  comment = "${each.key} user for trade pipeline in ${var.environment}"
}

# Grant roles to users
resource "snowflake_role_grants" "user_role_grants" {
  for_each = var.roles
  
  role_name = snowflake_role.roles[each.key].name
  users     = [for user in each.value.granted_to_users : snowflake_user.users[user].name]
}

# Create storage integration for GCS
resource "snowflake_storage_integration" "gcs_integration" {
  name    = "GCS_INTEGRATION_${upper(var.environment)}"
  comment = "GCS storage integration for ${var.environment}"
  type    = "EXTERNAL_STAGE"
  
  enabled = true
  
  storage_allowed_locations = var.storage_allowed_locations
  
  storage_provider = "GCS"
  
  storage_gcp_service_account = var.gcp_service_account_email
}

# Create network policy
resource "snowflake_network_policy" "access_policy" {
  name    = "ACCESS_POLICY_${upper(var.environment)}"
  comment = "Network access policy for ${var.environment}"
  
  allowed_ip_list = var.allowed_ip_ranges
}

# Apply network policy to account
resource "snowflake_account_grant" "network_policy" {
  privilege         = "APPLY NETWORK POLICY"
  roles             = [snowflake_role.roles["TRADE_ADMIN"].name]
  with_grant_option = true
}

# Create external tables (optional)
resource "snowflake_external_table" "raw_trades" {
  database = snowflake_database.trade_db.name
  schema   = snowflake_schema.schemas["RAW"].name
  name     = "RAW_TRADES_EXT"
  
  file_format = "TYPE = JSON"
  
  location = "@${snowflake_storage_integration.gcs_integration.name}/trades/raw/"
  
  column {
    name = "src"
    type = "VARIANT"
  }
  
  comment = "External table for raw trades from GCS"
}

# Create file format for JSON
resource "snowflake_file_format" "json_format" {
  database = snowflake_database.trade_db.name
  schema   = snowflake_schema.schemas["RAW"].name
  name     = "JSON_FORMAT"
  
  format_type = "JSON"
  
  compression = "AUTO"
  strip_outer_array = true
  ignore_utf8_errors = true
  
  comment = "JSON file format for trade data"
}

# Create stage for Snowpipe
resource "snowflake_stage" "trade_stage" {
  database = snowflake_database.trade_db.name
  schema   = snowflake_schema.schemas["RAW"].name
  name     = "TRADE_STAGE"
  
  url = "gcs://${var.gcp_project_id}-trade-data-${var.environment}/trades/"
  
  storage_integration = snowflake_storage_integration.gcs_integration.name
  
  file_format = snowflake_file_format.json_format.name
  
  comment = "GCS stage for Snowpipe ingestion"
}

# Create Snowpipe
resource "snowflake_pipe" "trade_pipe" {
  database = snowflake_database.trade_db.name
  schema   = snowflake_schema.schemas["RAW"].name
  name     = "TRADE_PIPE"
  
  copy_statement = <<-EOT
    COPY INTO ${snowflake_database.trade_db.name}.RAW.TRADES_STAGING
    FROM @${snowflake_database.trade_db.name}.RAW.TRADE_STAGE
    FILE_FORMAT = (FORMAT_NAME = '${snowflake_database.trade_db.name}.RAW.JSON_FORMAT')
    ON_ERROR = CONTINUE
  EOT
  
  auto_ingest = true
  
  comment = "Snowpipe for automatic trade ingestion"
}

# Create tasks for data transformation
resource "snowflake_task" "process_trades" {
  database = snowflake_database.trade_db.name
  schema   = snowflake_schema.schemas["PROCESSED"].name
  name     = "PROCESS_NEW_TRADES"
  
  warehouse = snowflake_warehouse.warehouses["transform"].name
  
  sql = <<-EOT
    BEGIN
      -- Process new trades from staging
      MERGE INTO ${snowflake_database.trade_db.name}.PROCESSED.VALID_TRADES vt
      USING (
        SELECT 
          RAW_DATA: trade_id::STRING as TRADE_ID,
          RAW_DATA: version::INTEGER as VERSION,
          -- ... other fields
        FROM ${snowflake_database.trade_db.name}.RAW.TRADES_STAGING
        WHERE METADATA$ACTION = 'INSERT'
      ) src
      ON vt.TRADE_ID = src.TRADE_ID AND vt.IS_CURRENT = TRUE
      WHEN MATCHED AND src.VERSION > vt.VERSION THEN
        UPDATE SET 
          vt.IS_CURRENT = FALSE,
          vt.VALID_TO = CURRENT_TIMESTAMP()
      WHEN NOT MATCHED THEN
        INSERT (TRADE_ID, VERSION, ...) 
        VALUES (src.TRADE_ID, src.VERSION, ...);
    END;
  EOT
  
  schedule = '5 MINUTE'
  
  comment = "Task to process new trades from staging"
}

# Create streams for CDC
resource "snowflake_stream" "trades_stream" {
  database = snowflake_database.trade_db.name
  schema   = snowflake_schema.schemas["RAW"].name
  name     = "TRADES_STREAM"
  
  on_table = "${snowflake_database.trade_db.name}.RAW.TRADES_STAGING"
  
  comment = "CDC stream for new trade records"
}

# Create masking policy for sensitive data
resource "snowflake_masking_policy" "trade_data_mask" {
  database = snowflake_database.trade_db.name
  schema   = snowflake_schema.schemas["PROCESSED"].name
  name     = "TRADE_DATA_MASK"
  
  masking_expression = <<-EOT
    CASE 
      WHEN CURRENT_ROLE() IN ('TRADE_ADMIN_${upper(var.environment)}', 'ACCOUNTADMIN') THEN val
      WHEN CURRENT_ROLE() = 'TRADE_ANALYST_${upper(var.environment)}' THEN 
        REGEXP_REPLACE(val, '(\\w{3})\\w+(\\w{3})', '\\1***\\2')
      ELSE '********'
    END
  EOT
  
  return_data_type = "STRING"
  
  comment = "Masking policy for sensitive trade data"
}

# Apply masking policy
resource "snowflake_table_column_masking_policy_application" "counterparty_mask" {
  table          = "${snowflake_database.trade_db.name}.PROCESSED.VALID_TRADES"
  column         = "COUNTERPARTY_ID"
  masking_policy = snowflake_masking_policy.trade_data_mask.qualified_name
}

# Create resource monitor for cost control
resource "snowflake_resource_monitor" "trade_monitor" {
  name         = "TRADE_MONITOR_${upper(var.environment)}"
  credit_quota = 1000
  
  frequency = "MONTHLY"
  
  start_timestamp = "IMMEDIATELY"
  
  notify_users = [
    snowflake_user.users["trade_admin"].name
  ]
}

# Assign resource monitor to warehouses
resource "snowflake_warehouse" "warehouses_with_monitor" {
  for_each = snowflake_warehouse.warehouses
  
  name           = each.value.name
  warehouse_size = each.value.warehouse_size
  # ... other properties ...
  
  resource_monitor = snowflake_resource_monitor.trade_monitor.name
  
  depends_on = [snowflake_resource_monitor.trade_monitor]
}
