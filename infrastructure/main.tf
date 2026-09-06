resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  suffix       = random_string.suffix.result
  storage_name = "stvoiceprompt${local.suffix}"
  common_tags = {
    application = "VoicePrompt"
    managed-by  = "Terraform"
  }
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-voiceprompt-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.42.0.0/16"]
  tags                = local.common_tags
}

resource "azurerm_subnet" "apps" {
  name                 = "snet-container-apps"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.42.0.0/23"]

  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "snet-private-endpoints"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = ["10.42.2.0/24"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_user_assigned_identity" "workload" {
  name                = "id-voiceprompt-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_container_registry" "main" {
  name                = "crvoiceprompt${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.common_tags
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-voiceprompt-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

resource "azurerm_application_insights" "main" {
  name                = "appi-voiceprompt-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
  tags                = local.common_tags
}

resource "azurerm_container_app_environment" "main" {
  name                           = "cae-voiceprompt-${local.suffix}"
  location                       = azurerm_resource_group.main.location
  resource_group_name            = azurerm_resource_group.main.name
  infrastructure_subnet_id       = azurerm_subnet.apps.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  internal_load_balancer_enabled = false
  zone_redundancy_enabled        = false
  tags                           = local.common_tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_storage_account" "main" {
  name                            = local.storage_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  tags                            = local.common_tags

  blob_properties {
    delete_retention_policy { days = 1 }
    container_delete_retention_policy { days = 1 }
  }
}

resource "azurerm_storage_container" "audio" {
  name                  = "audio"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_storage_queue" "work" {
  name               = "voice-work"
  storage_account_id = azurerm_storage_account.main.id
}

resource "azurerm_storage_queue" "poison" {
  name               = "voice-work-poison"
  storage_account_id = azurerm_storage_account.main.id
}

resource "azapi_resource" "tables" {
  for_each = toset(["sessions", "transcripts", "transcriptexpiry"])

  type      = "Microsoft.Storage/storageAccounts/tableServices/tables@2025-01-01"
  name      = each.key
  parent_id = "${azurerm_storage_account.main.id}/tableServices/default"
  body = {
    properties = {
      signedIdentifiers = []
    }
  }
}

resource "azurerm_storage_management_policy" "cleanup" {
  storage_account_id = azurerm_storage_account.main.id
  rule {
    name    = "delete-abandoned-audio"
    enabled = true
    filters {
      prefix_match = ["audio/"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob { delete_after_days_since_modification_greater_than = 1 }
    }
  }
}

resource "azurerm_private_dns_zone" "storage" {
  for_each = toset(["blob", "queue", "table"])

  name                = "privatelink.${each.key}.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage" {
  for_each = azurerm_private_dns_zone.storage

  name                  = "link-${each.key}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
}

resource "azurerm_private_endpoint" "storage" {
  for_each = toset(["blob", "queue", "table"])

  name                = "pe-${local.storage_name}-${each.key}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = azurerm_storage_account.main.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage[each.key].id]
  }
}

resource "azurerm_web_pubsub" "main" {
  name                          = "wps-voiceprompt-${local.suffix}"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  sku                           = "Free_F1"
  capacity                      = 1
  public_network_access_enabled = true
  local_auth_enabled            = false
  tags                          = local.common_tags
}

resource "azurerm_web_pubsub_hub" "main" {
  name          = "voiceprompt"
  web_pubsub_id = azurerm_web_pubsub.main.id
}

locals {
  app_environment = concat([
    { name = "AZURE_CLIENT_ID", value = azurerm_user_assigned_identity.workload.client_id },
    { name = "VOICEPROMPT_ENVIRONMENT", value = "production" },
    { name = "VOICEPROMPT_STORAGE_ACCOUNT_NAME", value = azurerm_storage_account.main.name },
    { name = "VOICEPROMPT_ENTRA_TENANT_ID", value = var.entra_tenant_id },
    { name = "VOICEPROMPT_ENTRA_AUDIENCE", value = var.entra_audience },
    { name = "VOICEPROMPT_ENTRA_REQUIRED_SCOPE", value = var.entra_required_scope },
    { name = "VOICEPROMPT_ALLOWED_ENTRA_OBJECT_IDS", value = join(",", var.allowed_entra_object_ids) },
    { name = "VOICEPROMPT_FOUNDRY_ENDPOINT", value = var.foundry_endpoint },
    { name = "VOICEPROMPT_SPEECH_DEPLOYMENT", value = var.speech_deployment },
    { name = "VOICEPROMPT_CLEANUP_DEPLOYMENT", value = var.cleanup_deployment },
    { name = "VOICEPROMPT_WEB_PUBSUB_ENDPOINT", value = "https://${azurerm_web_pubsub.main.hostname}" },
    { name = "APPLICATIONINSIGHTS_CONNECTION_STRING", value = azurerm_application_insights.main.connection_string },
    ], var.cleanup_temperature == null ? [] : [
    { name = "VOICEPROMPT_CLEANUP_TEMPERATURE", value = tostring(var.cleanup_temperature) },
  ])
}

resource "azurerm_container_app" "api" {
  name                         = "ca-voiceprompt-api-${local.suffix}"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.common_tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.workload.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.workload.id
  }

  depends_on = [
    azurerm_role_assignment.registry,
    azurerm_role_assignment.storage,
    azurerm_role_assignment.web_pubsub,
    azurerm_private_endpoint.storage,
    azapi_resource.tables,
    azurerm_storage_queue.work,
    azurerm_storage_queue.poison,
  ]

  ingress {
    external_enabled = true
    target_port      = 8000
    transport        = "http"
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0
    max_replicas = 2
    container {
      name   = "api"
      image  = var.container_image
      cpu    = 0.25
      memory = "0.5Gi"
      liveness_probe {
        transport        = "HTTP"
        port             = 8000
        path             = "/health/live"
        initial_delay    = 10
        interval_seconds = 30
      }
      readiness_probe {
        transport        = "HTTP"
        port             = 8000
        path             = "/health/ready"
        interval_seconds = 10
      }
      dynamic "env" {
        for_each = local.app_environment
        content {
          name  = env.value.name
          value = env.value.value
        }
      }
    }
    http_scale_rule {
      name                = "requests"
      concurrent_requests = 20
    }
  }
}

resource "azurerm_container_app_job" "worker" {
  name                         = "caj-voiceprompt-worker-${local.suffix}"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  replica_timeout_in_seconds   = 1200
  replica_retry_limit          = 2
  workload_profile_name        = "Consumption"
  tags                         = local.common_tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.workload.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.workload.id
  }

  depends_on = [
    azurerm_role_assignment.registry,
    azurerm_role_assignment.storage,
    azurerm_role_assignment.foundry,
    azurerm_role_assignment.web_pubsub,
    azurerm_private_endpoint.storage,
    azapi_resource.tables,
    azurerm_storage_queue.poison,
  ]

  event_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
    scale {
      min_executions              = 0
      max_executions              = 2
      polling_interval_in_seconds = 30
      rules {
        name             = "queue"
        custom_rule_type = "azure-queue"
        identity_id      = azurerm_user_assigned_identity.workload.id
        metadata = {
          accountName = azurerm_storage_account.main.name
          queueName   = azurerm_storage_queue.work.name
          queueLength = "1"
        }
      }
    }
  }

  template {
    container {
      name    = "worker"
      image   = var.container_image
      command = ["python", "-m", "voiceprompt.worker"]
      cpu     = 0.5
      memory  = "1Gi"
      dynamic "env" {
        for_each = local.app_environment
        content {
          name  = env.value.name
          value = env.value.value
        }
      }
    }
  }
}

resource "azurerm_container_app_job" "cleanup" {
  name                         = "caj-voiceprompt-cleanup-${local.suffix}"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  replica_timeout_in_seconds   = 300
  replica_retry_limit          = 2
  workload_profile_name        = "Consumption"
  tags                         = local.common_tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.workload.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.workload.id
  }

  depends_on = [
    azurerm_role_assignment.registry,
    azurerm_role_assignment.storage,
    azurerm_private_endpoint.storage,
    azapi_resource.tables,
  ]

  schedule_trigger_config {
    cron_expression          = "0 */1 * * *"
    parallelism              = 1
    replica_completion_count = 1
  }

  template {
    container {
      name    = "cleanup"
      image   = var.container_image
      command = ["python", "-m", "voiceprompt.cleanup"]
      cpu     = 0.25
      memory  = "0.5Gi"
      dynamic "env" {
        for_each = local.app_environment
        content {
          name  = env.value.name
          value = env.value.value
        }
      }
    }
  }
}
