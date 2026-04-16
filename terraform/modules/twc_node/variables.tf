variable "node_count" {
  description = "Количество серверов"
  type        = number
  default     = 1
}

variable "name_prefix" {
  description = "Префикс имени сервера"
  type        = string
}

variable "os_id" {
  description = "ID образа ОС"
  type        = number
}

variable "configurator_id" {
  description = "ID конфигуратора железа"
  type        = number
}

variable "project_id" {
  description = "ID проекта в Timeweb"
  type        = number
}

variable "ssh_key_id" {
  description = "ID добавленного SSH ключа"
  type        = number
}

variable "vpc_id" {
  description = "ID приватной сети"
  type        = string
}
