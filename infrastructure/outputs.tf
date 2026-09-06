output "api_url" {
  value = "https://${azurerm_container_app.api.latest_revision_fqdn}"
}

output "resource_names" {
  value = {
    resource_group = azurerm_resource_group.main.name
    api            = azurerm_container_app.api.name
    worker         = azurerm_container_app_job.worker.name
    cleanup        = azurerm_container_app_job.cleanup.name
    storage        = azurerm_storage_account.main.name
    web_pubsub     = azurerm_web_pubsub.main.name
  }
}

