variable "subscription_id" {
  type        = string
  description = "Azure subscription ID."
}

variable "location" {
  type        = string
  default     = "westeurope"
  description = "Azure region."
}

variable "resource_group_name" {
  type        = string
  default     = "rg-voiceprompt-prod"
  description = "App-specific resource group."
}

variable "container_image" {
  type        = string
  description = "Immutable backend image reference."
}

variable "allowed_google_subjects" {
  type        = list(string)
  sensitive   = true
  default     = []
  description = "Allowed stable Google subject identifiers."
}

variable "google_audiences" {
  type        = list(string)
  default     = []
  description = "Native Google OIDC client IDs."
}

variable "foundry_endpoint" {
  type        = string
  default     = ""
  description = "Existing Microsoft Foundry endpoint."
}

variable "foundry_resource_id" {
  type        = string
  default     = ""
  description = "Resource ID of the existing Microsoft Foundry account used for RBAC."
}

variable "speech_deployment" {
  type        = string
  default     = ""
  description = "Existing speech-capable deployment name selected after evaluation."
}

variable "cleanup_deployment" {
  type        = string
  default     = "gpt-5.6-luna"
  description = "Existing cleanup deployment name."
}
