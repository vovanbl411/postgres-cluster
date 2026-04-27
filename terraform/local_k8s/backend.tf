terraform {
    backend "s3" {
    bucket = "terraform-state"
    key    = "k8s-cluster/terraform.tfstate"
    region = "eu-central-1"

    endpoints = {
      s3 = "http://localhost:9000"
    }

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    use_path_style              = true
  }

}