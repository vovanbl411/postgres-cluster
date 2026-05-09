terraform {
  backend "s3" {
    bucket                      = "terraform-state"
    key                         = "docker-swarm-cluster/terraform.tfstate"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    use_path_style              = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    # region                      = "auto"
    # endpoint будут заданы в workflow

  #   endpoints = {
  #   s3 = "https://3c0b9323abd28c04275c43d1be673fb5.r2.cloudflarestorage.com"
  # }

  }
}
