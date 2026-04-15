terraform {
  required_providers {
    twc = {
      source = "tf.timeweb.cloud/timeweb-cloud/timeweb-cloud"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.40.0"
    }
  }
  required_version = ">= 0.13"
}

# Provider для Timeweb Cloud
provider "twc" {
  token = var.timeweb_token
}

# Provider для Cloudflare
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
