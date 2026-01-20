# infrastructure/versions.tf
# Versions of various components acceptatble to run TF scripts
# 
terraform {
  required_version = ">= 1.0.0"
  
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.34.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 4.34.0"
    }
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = ">= 0.40.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.1.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.7.2"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.1.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 3.1.0"
    }
  }
}
