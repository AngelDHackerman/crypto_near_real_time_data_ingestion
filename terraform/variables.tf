variable "aws_region" {
  description = "AWS Region"
  type = string
}
variable "environment" {
  description = "environment name"
  type = string
}
variable "secrets_manager_arn" {
  description = "secrets manager"
  type = string
}
variable "secrets_manager_name" {
  description = "secrets manager name"
  type = string
}
variable "bucket_lake_raw_name" {
  description = "Lake Raw Bucket Name"
  type = string
}
variable "bronze_prefix" {
  description = "prefix for bronze data"  
  type = string
}
variable "top10_list_symbol" {
  description = "An array of coins I want to record"
  type = list(string)
}
variable "top10_list_id" {
  description = "Id of the coins to record"
  type = list(number)
}