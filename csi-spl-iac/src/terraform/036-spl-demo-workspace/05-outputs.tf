output "demo_workspace" {
  value       = var.demo_enabled ? var.demo_workspace : ""
  description = "The demo workspace this env's state ensures; empty while the demo is off."
}
