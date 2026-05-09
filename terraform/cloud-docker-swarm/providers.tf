terraform {
  required_providers {
    
    twc = {
      source = "tf.timeweb.cloud/timeweb-cloud/timeweb-cloud"
    }
  }
  
  # Version terraform
  required_version = "~> 1.5"
}

provider "twc" {
  token = var.timeweb_token
}

