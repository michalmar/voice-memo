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

variable "entra_tenant_id" {
  type        = string
  description = "Microsoft Entra tenant ID."
}

variable "entra_audience" {
  type        = string
  description = "API application client ID expected in Entra v2 access tokens."
}

variable "entra_required_scope" {
  type        = string
  default     = "VoicePrompt.Access"
  description = "Delegated API scope required in access tokens."
}

variable "allowed_entra_object_ids" {
  type        = list(string)
  sensitive   = true
  default     = []
  description = "Allowed stable Entra user object IDs."
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
