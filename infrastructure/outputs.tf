output "api_url" {
  value = "https://${azurerm_container_app.api.ingress[0].fqdn}"
}

output "resource_names" {
  value = {
    resource_group = azurerm_resource_group.main.name
    api            = azurerm_container_app.api.name
    worker         = azurerm_container_app_job.worker.name
    cleanup        = azurerm_container_app_job.cleanup.name
    storage        = azurerm_storage_account.main.name
    web_pubsub     = azurerm_web_pubsub.main.name
    registry       = azurerm_container_registry.main.name
  }
}

output "registry_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "workload_identity" {
  value = {
    id           = azurerm_user_assigned_identity.workload.id
    client_id    = azurerm_user_assigned_identity.workload.client_id
    principal_id = azurerm_user_assigned_identity.workload.principal_id
  }
}
