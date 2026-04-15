variable "timeweb_token" {
  description = "Timeweb Cloud API Token"
  type        = string
  default     = ""
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "CloudFlare API token (для локального тестирования через файл)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "region" {
  description = "Location for resources"
  type        = string
  default     = "ru-1"
}

variable "instance_count" {
  default = 3
}

variable "ssh_public_key" {
  description = "Публичный ключ для доступа к нодам"
  type = string
}
