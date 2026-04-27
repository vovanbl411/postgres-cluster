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
  
  # Version terraform
  required_version = "~> 1.5"
}

provider "twc" {
  token = var.timeweb_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
